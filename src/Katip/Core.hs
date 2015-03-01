{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}

module Katip.Core where

-------------------------------------------------------------------------------
import           Control.Applicative
import           Control.AutoUpdate
import           Control.Concurrent
import           Control.Lens
import           Control.Monad.Reader
import           Data.Aeson                 (ToJSON (..))
import qualified Data.Aeson                 as A
import           Data.Aeson.Lens
import qualified Data.HashMap.Strict        as HM
import           Data.List
import qualified Data.Map.Strict            as M
import           Data.Monoid
import           Data.String
import           Data.String.Conv
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Time
import           GHC.Generics               hiding (to)
import           Language.Haskell.TH
import qualified Language.Haskell.TH.Syntax as TH
import           Network.HostName
import           System.Posix
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
newtype Namespace = Namespace { getNamespace :: [Text] }
  deriving (Eq,Show,Read,Ord,Generic,ToJSON,Monoid)

instance IsString Namespace where
    fromString s = Namespace [fromString s]


-------------------------------------------------------------------------------
-- | Ready namespace for emission with dots to join the segments.
intercalateNs :: Namespace -> [Text]
intercalateNs (Namespace xs) = intersperse "." xs


-------------------------------------------------------------------------------
-- | Application environment, like @prod@, @devel@, @testing@.
newtype Environment = Environment { getEnvironment :: Text }
  deriving (Eq,Show,Read,Ord,Generic,ToJSON,IsString)


-------------------------------------------------------------------------------
data Severity
    = Debug                   -- ^ Debug messages
    | Info                    -- ^ Information
    | Notice                  -- ^ Normal runtime Conditions
    | Warning                 -- ^ General Warnings
    | Error                   -- ^ General Errors
    | Critical                -- ^ Severe situations
    | Alert                   -- ^ Take immediate action
    | Emergency               -- ^ System is unusable
  deriving (Eq, Ord, Show, Read, Generic)


-------------------------------------------------------------------------------
-- | Verbosity controls the amount of information (columns) a 'Scribe'
-- emits during logging.
--
-- The convention is:
-- - 'V0' implies no additional payload information is included in message.
-- - 'V3' implies the maximum amount of payload information.
-- - Anything in between is left to the discretion of the developer.
data Verbosity = V0 | V1 | V2 | V3
  deriving (Eq, Ord, Show, Read, Generic)


-------------------------------------------------------------------------------
renderSeverity :: Severity -> Text
renderSeverity s = case s of
      Debug -> "Debug"
      Info -> "Info"
      Notice -> "Notice"
      Warning -> "Warning"
      Error -> "Error"
      Critical -> "Critical"
      Alert -> "Alert"
      Emergency -> "Emergency"


-------------------------------------------------------------------------------
instance ToJSON Severity where
    toJSON s = A.String (renderSeverity s)


-------------------------------------------------------------------------------
-- | This has everything each log message will contain.
data Item a = Item {
      itemApp       :: Namespace
    , itemEnv       :: Environment
    , itemSeverity  :: Severity
    , itemThread    :: ThreadId
    , itemHost      :: HostName
    , itemProcess   :: ProcessID
    , itemPayload   :: a
    , itemMessage   :: Text
    , itemTime      :: UTCTime
    , itemNamespace :: Namespace
    , itemLoc       :: Maybe Loc
    } deriving (Generic)



instance ToJSON a => ToJSON (Item a) where
    toJSON Item{..} = A.object
      [ "app" A..= itemApp
      , "env" A..= itemEnv
      , "sev" A..= itemSeverity
      , "thread" A..= show itemThread
      , "host" A..= itemHost
      , "pid" A..= A.String (toS (show itemProcess))
      , "data" A..= itemPayload
      , "msg" A..= itemMessage
      , "at" A..= itemTime
      , "ns" A..= itemNamespace
      ]


-------------------------------------------------------------------------------
-- | Field selector by verbosity within JSON payload.
data PayloadSelection
    = AllKeys
    | SomeKeys [Text]

-------------------------------------------------------------------------------
-- | Payload objects need instances of this class.
class ToJSON a => LogContext a where

    -- | List of keys in the JSON object that should be included in message.
    payloadKeys :: Verbosity -> a -> PayloadSelection


instance LogContext () where payloadKeys _ _ = SomeKeys []


-------------------------------------------------------------------------------
-- | Constrain payload based on verbosity. To be used by backends.
payloadJson :: LogContext a => Verbosity -> a -> A.Value
payloadJson v a = case payloadKeys v a of
    AllKeys -> toJSON a
    SomeKeys ks -> toJSON a
      & _Object %~ HM.filterWithKey (\ k v -> k `elem` ks)


-------------------------------------------------------------------------------
-- | Scribes are handlers of incoming items. Each registered scribe
-- knows how to push a log item somewhere.
data Scribe = Scribe {
      lhPush :: forall a. LogContext a => Item a -> IO ()
    }


instance Monoid Scribe where
    mempty = Scribe $ const $ return ()
    mappend (Scribe a) (Scribe b) = Scribe $ \ item -> do
      a item
      b item

-------------------------------------------------------------------------------
data LogEnv = LogEnv {
      _logEnvHost     :: HostName
    , _logEnvPid      :: ProcessID
    , _logEnvApp      :: Namespace
    , _logEnvEnv      :: Environment
    , _logEnvTimer    :: IO UTCTime
    , _logEnvHandlers :: M.Map Text Scribe
    }
makeLenses ''LogEnv


-------------------------------------------------------------------------------
initLogEnv
    :: Namespace
    -- ^ A base namespace for this application
    -> Environment
    -- ^ Current run environment (e.g. @prod@ vs. @devel@)
    -> IO LogEnv
initLogEnv an env = LogEnv
  <$> getHostName
  <*> getProcessID
  <*> pure an
  <*> pure env
  <*> mkAutoUpdate defaultUpdateSettings { updateAction = getCurrentTime }
  <*> pure mempty


-------------------------------------------------------------------------------
registerHandler
    :: Text
    -- ^ Name the handler
    -> Scribe
    -> LogEnv
    -> LogEnv
registerHandler nm h = logEnvHandlers . at nm .~ Just h


-------------------------------------------------------------------------------
unregisterHandler
    :: Text
    -- ^ Name of the handler
    -> LogEnv
    -> LogEnv
unregisterHandler nm = logEnvHandlers . at nm .~ Nothing



class Katip m where
    getLogEnv :: m LogEnv


-------------------------------------------------------------------------------
-- | Log with everything, including a source code location.
logI
    :: (Applicative m, MonadIO m, LogContext a, Katip m)
    => a
    -> Namespace
    -> Maybe Loc
    -> Severity
    -> Text
    -> m ()
logI a ns loc sev msg = do
    LogEnv{..} <- getLogEnv
    item <- Item
      <$> pure _logEnvApp
      <*> pure _logEnvEnv
      <*> pure sev
      <*> liftIO myThreadId
      <*> pure _logEnvHost
      <*> pure _logEnvPid
      <*> pure a
      <*> pure msg
      <*> liftIO _logEnvTimer
      <*> pure (_logEnvApp <> ns)
      <*> pure loc
    liftIO $ forM_ (M.elems _logEnvHandlers) $ \ (Scribe h) -> h item


-------------------------------------------------------------------------------
-- | Log with full context.
logF
  :: (Applicative m, MonadIO m, LogContext a, Katip m)
  => a
  -- ^ Contextual payload for the log
  -> Namespace
  -- ^ Specific namespace of the message.
  -> Severity
  -- ^ Severity of the message
  -> Text
  -- ^ The log message
  -> m ()
logF a ns sev msg = logI a ns Nothing sev msg


-------------------------------------------------------------------------------
-- | Log a message without any payload/context.
logM
    :: (Applicative m, MonadIO m, Katip m)
    => Namespace
    -> Severity
    -> Text
    -> m ()
logM ns sev msg = logF () ns sev msg


instance TH.Lift Namespace where
    lift (Namespace xs) =
      let xs' = map T.unpack xs
      in  [| Namespace (map T.pack xs') |]


instance TH.Lift Verbosity where
    lift V0 = [| V0 |]
    lift V1 = [| V1 |]
    lift V2 = [| V2 |]
    lift V3 = [| V3 |]


instance TH.Lift Severity where
    lift Debug = [| Debug |]
    lift Info  = [| Info |]
    lift Notice  = [| Notice |]
    lift Warning  = [| Warning |]
    lift Error  = [| Error |]
    lift Critical  = [| Critical |]
    lift Alert  = [| Alert |]
    lift Emergency  = [| Emergency |]


-- | Lift a location into an Exp.
liftLoc :: Loc -> Q Exp
liftLoc (Loc a b c (d1, d2) (e1, e2)) = [|Loc
    $(TH.lift a)
    $(TH.lift b)
    $(TH.lift c)
    ($(TH.lift d1), $(TH.lift d2))
    ($(TH.lift e1), $(TH.lift e2))
    |]


-------------------------------------------------------------------------------
-- | For use when you want to include location in your logs. This will
-- fill the 'Maybe Loc' gap in 'logF' of this module.
getLoc :: Q Exp
getLoc = [| $(location >>= liftLoc) |]


-------------------------------------------------------------------------------
-- | 'Loc'-tagged logging when using template-haskell is OK.
logT :: ExpQ
logT = [| \ a ns sev msg -> logI a ns (Just $(location >>= liftLoc)) sev msg |]


-- taken from the file-location package
-- turn the TH Loc loaction information into a human readable string
-- leaving out the loc_end parameter
locationToString :: Loc -> String
locationToString loc = (loc_package loc) ++ ':' : (loc_module loc) ++
  ' ' : (loc_filename loc) ++ ':' : (line loc) ++ ':' : (char loc)
  where
    line = show . fst . loc_start
    char = show . snd . loc_start