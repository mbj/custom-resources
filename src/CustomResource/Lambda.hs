-- @see https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/crpg-ref.html
module CustomResource.Lambda
  ( Debug(..)
  , FromPhysicalResourceId(..)
  , PhysicalResourceId(..)
  , Request
  , RequestHandler
  , RequestMetadata(..)
  , ResourceHandler(..)
  , ResourceType
  , Response
  , ResponseData(..)
  , ResponseDataEcho(..)
  , ResponseReason(..)
  , ResponseStatus(..)
  , State(..)
  , ToPhysicalResourceId(..)
  , check
  , emptyResponseData
  , mkFailedResponse
  , mkRequestHandler
  , mkResourceType
  , mkResponse
  , mkSuccessResponse
  , requestMetadata
  , run
  , unknownPhysicalResourceId
  )
where

import Control.Monad.Fail (fail)
import CustomResource.AWS
import CustomResource.Prelude
import Data.Aeson (FromJSON, ToJSON, (.:))
import Data.Map.Strict (Map)
import Data.String (String)
import GHC.Generics (Generic)
import System.IO (IO)

import qualified AWS.Lambda.Runtime      as Lambda
import qualified Data.Aeson              as JSON
import qualified Data.Aeson.Types        as JSON
import qualified Data.Map.Strict         as Map
import qualified Data.Text.IO            as Text
import qualified Network.HTTP.Client     as HTTP
import qualified Network.HTTP.Client.TLS as HTTP

data State = New | Old

newtype LogicalResourceId = LogicalResourceId Text
  deriving newtype (Eq, FromJSON, Show, ToJSON, ToText)

newtype PhysicalResourceId = PhysicalResourceId Text
  deriving newtype (Eq, FromJSON, Show, ToJSON, ToText)

newtype ResourceProperties :: State -> * where
  ResourceProperties :: JSON.Object -> ResourceProperties a
  deriving newtype FromJSON
  deriving stock   Show

newtype ResourceType = ResourceType Text
  deriving newtype (Eq, FromJSON, Ord, Show, ToJSON, ToText)

newtype ResponseReason = ResponseReason Text
  deriving newtype (Eq, FromJSON, Show, ToJSON, ToText)

newtype ResponseURL = ResponseURL Text
  deriving newtype (Eq, FromJSON, Show, ToJSON, ToText)

newtype RequestId = RequestId Text
  deriving newtype (Eq, FromJSON, Show, ToJSON, ToText)

newtype ServiceToken = ServiceToken Text
  deriving newtype (Eq, FromJSON, Show, ToJSON, ToText)

newtype StackId = StackId Text
  deriving newtype (Eq, FromJSON, Show, ToJSON, ToText)

class ToPhysicalResourceId a where
  toPhysicalResourceId :: a -> PhysicalResourceId

instance ToPhysicalResourceId PhysicalResourceId where
  toPhysicalResourceId = identity

class FromPhysicalResourceId a where
  fromPhysicalResourceId :: PhysicalResourceId -> Either String a

data Handler = Handler
  { create
      :: RequestMetadata
      -> ResourceProperties 'New
      -> AWS Response
  , delete
      :: RequestMetadata
      -> PhysicalResourceId
      -> AWS Response
  , update
      :: RequestMetadata
      -> PhysicalResourceId
      -> ResourceProperties 'New
      -> ResourceProperties 'Old
      -> AWS Response
  }

data ResourceHandler id properties = ResourceHandler
  { createResource
      :: RequestMetadata
      -> properties 'New
      -> AWS Response
  , deleteResource
      :: RequestMetadata
      -> id
      -> AWS Response
  , updateResource
      :: RequestMetadata
      -> id
      -> properties 'New
      -> properties 'Old
      -> AWS Response
  }

newtype RequestHandler = RequestHandler (Map ResourceType Handler)

data Request
  = Create RequestMetadata (ResourceProperties 'New)
  | Delete RequestMetadata PhysicalResourceId
  | Update
      RequestMetadata
      PhysicalResourceId
      (ResourceProperties 'New)
      (ResourceProperties 'Old)
  deriving stock Show

data RequestMetadata = RequestMetadata
  { logicalResourceId :: LogicalResourceId
  , requestId         :: RequestId
  , resourceType      :: ResourceType
  , responseURL       :: ResponseURL
  , serviceToken      :: ServiceToken
  , stackId           :: StackId
  }
  deriving stock (Generic, Show)

instance FromJSON RequestMetadata where
  parseJSON = JSON.withObject "request metadata" $ \value -> do
    logicalResourceId <- JSON.parseJSON =<< value .: "LogicalResourceId"
    requestId         <- JSON.parseJSON =<< value .: "RequestId"
    resourceType      <- JSON.parseJSON =<< value .: "ResourceType"
    responseURL       <- JSON.parseJSON =<< value .: "ResponseURL"
    serviceToken      <- JSON.parseJSON =<< value .: "ServiceToken"
    stackId           <- JSON.parseJSON =<< value .: "StackId"

    pure RequestMetadata{..}

instance FromJSON Request where
  parseJSON = JSON.withObject "Request" parseRequest
    where
      parseRequest :: JSON.Object -> JSON.Parser Request
      parseRequest input = do
        metadata    <- JSON.parseJSON (JSON.Object input)
        requestType <- input .: "RequestType"

        JSON.withText "RequestType" (parseRequest' metadata input) requestType

      parseRequest'
        :: RequestMetadata
        -> JSON.Object
        -> Text
        -> JSON.Parser Request
      parseRequest' metadata input requestType =
        case requestType of
          "Create" -> Create metadata <$> input .: "ResourceProperties"
          "Delete" -> Delete metadata <$> input .: "PhysicalResourceId"
          "Update" ->
                Update metadata
            <$> input .: "PhysicalResourceId"
            <*> input .: "ResourceProperties"
            <*> input .: "OldResourceProperties"
          _ -> fail $ convertText ("Unexpectd RequestType: " <> requestType)

data ResponseStatus = SUCCESS | FAILED
  deriving anyclass ToJSON
  deriving stock    (Generic, Show)

newtype ResponseData = ResponseData (Map Text Text)
  deriving newtype ToJSON
  deriving stock   Show

data ResponseDataEcho = Echo | NoEcho
  deriving stock (Eq, Show)

instance JSON.ToJSON ResponseDataEcho where
  toJSON = \case
    Echo   -> JSON.Bool False
    NoEcho -> JSON.Bool True

data Response = Response
  { data'              :: ResponseData
  , echo               :: ResponseDataEcho
  , logicalResourceId  :: LogicalResourceId
  , physicalResourceId :: PhysicalResourceId
  , reason             :: ResponseReason
  , requestId          :: RequestId
  , stackId            :: StackId
  , status             :: ResponseStatus
  }
  deriving stock    (Generic, Show)

instance ToJSON Response where
  toJSON Response{..} = JSON.object
    [ ("Data",               JSON.toJSON data')
    , ("LogicalResourceId",  JSON.toJSON logicalResourceId)
    , ("NoEcho",             JSON.toJSON echo)
    , ("PhysicalResourceId", JSON.toJSON physicalResourceId)
    , ("Reason",             JSON.toJSON reason)
    , ("RequestId",          JSON.toJSON requestId)
    , ("StackId",            JSON.toJSON stackId)
    , ("Status",             JSON.toJSON status)
    ]

data Debug = DoDebug | NoDebug

run :: MonadIO m => Debug -> RequestHandler -> m ()
run debug handlers = liftIO
  (Lambda.ioRuntime . runtime debug handlers =<< HTTP.newTlsManager)

runtime
  :: Debug
  -> RequestHandler
  -> HTTP.Manager
  -> Request
  -> IO (Either String JSON.Value)
runtime debug handlers manager request = do
  doDebug
  sendResponse manager (responseURL $ requestMetadata request) =<<
    withEnv (handleRequest handlers request)

  pure . Right $ JSON.toJSON True
  where
    doDebug = case debug of
      DoDebug -> liftIO . Text.putStrLn . convertText $ show request
      NoDebug -> pure ()

handleRequest :: RequestHandler -> Request -> AWS Response
handleRequest (RequestHandler handlers) request
  = maybe (unsupportedHandler request) (runHandler request)
  $ Map.lookup requestResourceType handlers
  where
    requestResourceType = resourceType $ requestMetadata request

    unsupportedHandler = \case
      Create metadata _properties ->
        mkFailedResponse metadata unknownPhysicalResourceId reason
      Delete metadata physicalResourceId ->
        pure $ mkSuccessResponse metadata physicalResourceId
      Update metadata physicalResourceId _newProperties _oldProperties ->
        mkFailedResponse metadata physicalResourceId reason

    reason
      = ResponseReason
      $ "Not implemented resource type: " <> convertText requestResourceType

runHandler :: Request -> Handler -> AWS Response
runHandler request Handler{..} =
  case request of
    Create metadata properties ->
      create metadata properties
    Delete metadata physicalResourceId ->
      delete metadata physicalResourceId
    Update metadata physicalResourceId newProperties oldProperties ->
      update metadata physicalResourceId newProperties oldProperties

sendResponse :: MonadIO m => HTTP.Manager -> ResponseURL -> Response -> m ()
sendResponse manager url response = do
  request <- setup <$> (liftIO . HTTP.parseRequest $ convertText url)
  void . liftIO $ HTTP.httpNoBody request manager
  pure ()
  where
    setup :: HTTP.Request -> HTTP.Request
    setup request = request
      { HTTP.method      = "PUT"
      , HTTP.requestBody = HTTP.RequestBodyLBS $ JSON.encode response
      }

mkResponse
  :: ToPhysicalResourceId a
  => RequestMetadata
  -> ResponseStatus
  -> a
  -> ResponseData
  -> ResponseDataEcho
  -> ResponseReason
  -> Response
mkResponse RequestMetadata{..} status resourceId data' echo reason =
 Response
   { physicalResourceId = toPhysicalResourceId resourceId
   , ..
   }

mkSuccessResponse
  :: ToPhysicalResourceId a
  => RequestMetadata
  -> a
  -> Response
mkSuccessResponse metadata resourceId
  = mkResponse
    metadata
    SUCCESS
    resourceId
    emptyResponseData
    NoEcho
    (ResponseReason "SUCCESS")

mkFailedResponse
  :: (ToPhysicalResourceId a, ToText b)
  => RequestMetadata
  -> a
  -> b
  -> AWS Response
mkFailedResponse metadata resourceId
  = pure
  . mkResponse metadata FAILED resourceId emptyResponseData NoEcho
  . ResponseReason
  . convertText

requestMetadata :: Request -> RequestMetadata
requestMetadata = \case
  (Create value _)     -> value
  (Delete value _)     -> value
  (Update value _ _ _) -> value

unknownPhysicalResourceId :: PhysicalResourceId
unknownPhysicalResourceId = PhysicalResourceId "unknown"

-- Turn a resource handler into a generic handler (void of type holes)
-- so we can make it member of a higher level data structure.
--
-- This the wrapper to counteract the absence of DTs.
mkRequestHandler
  :: forall id (properties :: State -> *) .
     ( FromJSON (properties 'New)
     , FromJSON (properties 'Old)
     )
  => FromPhysicalResourceId id
  => ResourceType
  -> ResourceHandler id properties
  -> RequestHandler
mkRequestHandler resourceType ResourceHandler{..} =
  RequestHandler $ Map.singleton resourceType Handler{..}
  where
    create metadata properties =
      withNewProperties
        metadata
        unknownPhysicalResourceId
        properties
        (createResource metadata)

    update metadata physicalResourceId newProperties oldProperties =
      withPhysicalResourceId
        metadata
        physicalResourceId $ \id ->
          withNewProperties metadata physicalResourceId newProperties $ \new ->
            withOldProperties metadata physicalResourceId oldProperties $ \old ->
              updateResource metadata id new old

    delete metadata physicalResourceId =
      if physicalResourceId == unknownPhysicalResourceId
        then
          pure $
            mkResponse
              metadata
              SUCCESS
              physicalResourceId
              emptyResponseData
              NoEcho
              (ResponseReason "Resource properties failed to parse, skipping delete")
        else
          withPhysicalResourceId
            metadata
            physicalResourceId
            (deleteResource metadata)

    withPhysicalResourceId
      :: RequestMetadata
      -> PhysicalResourceId
      -> (id -> AWS Response)
      -> AWS Response
    withPhysicalResourceId metadata physicalResourceId action =
      either
        (failResponse metadata physicalResourceId)
        action
        (fromPhysicalResourceId physicalResourceId)

    withOldProperties
      :: RequestMetadata
      -> PhysicalResourceId
      -> ResourceProperties 'Old
      -> (properties 'Old -> AWS Response)
      -> AWS Response
    withOldProperties metadata physicalResourceId (ResourceProperties object) action =
      either
        (failResponse metadata physicalResourceId)
        action
      $ JSON.parseEither JSON.parseJSON (JSON.Object object)

    withNewProperties
      :: RequestMetadata
      -> PhysicalResourceId
      -> ResourceProperties 'New
      -> (properties 'New -> AWS Response)
      -> AWS Response
    withNewProperties metadata physicalResourceId (ResourceProperties object) action =
      either
        (failResponse metadata physicalResourceId)
        action
      $ JSON.parseEither JSON.parseJSON (JSON.Object object)

    failResponse :: RequestMetadata -> PhysicalResourceId -> String -> AWS Response
    failResponse = mkFailedResponse

check
  :: ToPhysicalResourceId a
  => RequestMetadata
  -> a
  -> AWS Response
  -> Text
  -> Bool
  -> AWS Response
check metadata resourceId action message = \case
  True  -> action
  False ->
    pure $
      mkResponse
        metadata
        FAILED
        resourceId
        emptyResponseData
        NoEcho
        (ResponseReason message)

mkResourceType :: Text -> ResourceType
mkResourceType = ResourceType . ("Custom::" <>)

emptyResponseData :: ResponseData
emptyResponseData = ResponseData Map.empty
