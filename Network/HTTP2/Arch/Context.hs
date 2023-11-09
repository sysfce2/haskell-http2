{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

module Network.HTTP2.Arch.Context where

import Data.IORef
import Network.HTTP.Types (Method)
import Network.Socket (SockAddr)
import UnliftIO.STM

import Imports hiding (insert)
import Network.HPACK
import Network.HTTP2.Arch.Rate
import Network.HTTP2.Arch.Stream
import Network.HTTP2.Arch.StreamTable
import Network.HTTP2.Arch.Types
import Network.HTTP2.Frame

data Role = Client | Server deriving (Eq, Show)

----------------------------------------------------------------

data RoleInfo = RIS ServerInfo | RIC ClientInfo

data ServerInfo = ServerInfo
    { inputQ :: TQueue (Input Stream)
    }

data ClientInfo = ClientInfo
    { scheme :: ByteString
    , authority :: ByteString
    }

toServerInfo :: RoleInfo -> ServerInfo
toServerInfo (RIS x) = x
toServerInfo _ = error "toServerInfo"

toClientInfo :: RoleInfo -> ClientInfo
toClientInfo (RIC x) = x
toClientInfo _ = error "toClientInfo"

newServerInfo :: IO RoleInfo
newServerInfo = RIS . ServerInfo <$> newTQueueIO

newClientInfo :: ByteString -> ByteString -> RoleInfo
newClientInfo scm auth = RIC $ ClientInfo scm auth

----------------------------------------------------------------

-- | The context for HTTP/2 connection.
data Context = Context
    { role :: Role
    , roleInfo :: RoleInfo
    , -- Settings
      myFirstSettings :: IORef Bool
    , myPendingAlist :: IORef (Maybe SettingsList)
    , mySettings :: IORef Settings
    , peerSettings :: IORef Settings
    , oddStreamTable :: IORef OddStreamTable
    , evenStreamTable :: IORef EvenStreamTable
    , continued :: IORef (Maybe StreamId)
    -- ^ RFC 9113 says "Other frames (from any stream) MUST NOT
    --   occur between the HEADERS frame and any CONTINUATION
    --   frames that might follow". This field is used to implement
    --   this requirement.
    , myStreamId :: IORef StreamId
    , peerStreamId :: IORef StreamId
    , outputBufferLimit :: IORef Int
    , outputQ :: TQueue (Output Stream)
    , outputQStreamID :: TVar StreamId
    , controlQ :: TQueue Control
    , encodeDynamicTable :: DynamicTable
    , decodeDynamicTable :: DynamicTable
    , -- the connection window for sending data
      txConnectionWindow :: TVar WindowSize
    , -- window update for receiving data
      rxConnectionInc :: IORef WindowSize -- this is diff
    , pingRate :: Rate
    , settingsRate :: Rate
    , emptyFrameRate :: Rate
    , rstRate :: Rate
    , mySockAddr :: SockAddr
    , peerSockAddr :: SockAddr
    }

----------------------------------------------------------------

newContext
    :: RoleInfo -> Int -> BufferSize -> SockAddr -> SockAddr -> IO Context
newContext rinfo cacheSiz siz mysa peersa =
    Context rl rinfo
        <$> newIORef False
        <*> newIORef Nothing
        <*> newIORef defaultSettings
        <*> newIORef defaultSettings
        <*> newIORef emptyOddStreamTable
        <*> newIORef (emptyEvenStreamTable cacheSiz)
        <*> newIORef Nothing
        <*> newIORef sid0
        <*> newIORef 0
        <*> newIORef buflim
        <*> newTQueueIO
        <*> newTVarIO sid0
        <*> newTQueueIO
        -- My SETTINGS_HEADER_TABLE_SIZE
        <*> newDynamicTableForEncoding defaultDynamicTableSize
        <*> newDynamicTableForDecoding defaultDynamicTableSize 4096
        <*> newTVarIO defaultWindowSize
        <*> newIORef 0
        <*> newRate
        <*> newRate
        <*> newRate
        <*> newRate
        <*> return mysa
        <*> return peersa
  where
    rl = case rinfo of
        RIC{} -> Client
        _ -> Server
    sid0
        | rl == Client = 1
        | otherwise = 2
    dlim = defaultPayloadLength + frameHeaderLength
    buflim
        | siz >= dlim = dlim
        | otherwise = siz

----------------------------------------------------------------

isClient :: Context -> Bool
isClient ctx = role ctx == Client

isServer :: Context -> Bool
isServer ctx = role ctx == Server

----------------------------------------------------------------

getMyNewStreamId :: Context -> IO StreamId
getMyNewStreamId ctx = atomicModifyIORef' (myStreamId ctx) inc2
  where
    inc2 n = let n' = n + 2 in (n', n)

getPeerStreamID :: Context -> IO StreamId
getPeerStreamID ctx = readIORef $ peerStreamId ctx

setPeerStreamID :: Context -> StreamId -> IO ()
setPeerStreamID ctx sid = writeIORef (peerStreamId ctx) sid

----------------------------------------------------------------

{-# INLINE setStreamState #-}
setStreamState :: Context -> Stream -> StreamState -> IO ()
setStreamState _ Stream{streamState} val = writeIORef streamState val

opened :: Context -> Stream -> IO ()
opened ctx strm = setStreamState ctx strm (Open Nothing JustOpened)

halfClosedRemote :: Context -> Stream -> IO ()
halfClosedRemote ctx stream@Stream{streamState} = do
    closingCode <- atomicModifyIORef streamState closeHalf
    traverse_ (closed ctx stream) closingCode
  where
    closeHalf :: StreamState -> (StreamState, Maybe ClosedCode)
    closeHalf x@(Closed _) = (x, Nothing)
    closeHalf (Open (Just cc) _) = (Closed cc, Just cc)
    closeHalf _ = (HalfClosedRemote, Nothing)

halfClosedLocal :: Context -> Stream -> ClosedCode -> IO ()
halfClosedLocal ctx stream@Stream{streamState} cc = do
    shouldFinalize <- atomicModifyIORef streamState closeHalf
    when shouldFinalize $
        closed ctx stream cc
  where
    closeHalf :: StreamState -> (StreamState, Bool)
    closeHalf x@(Closed _) = (x, False)
    closeHalf HalfClosedRemote = (Closed cc, True)
    closeHalf (Open Nothing o) = (Open (Just cc) o, False)
    closeHalf _ = (Open (Just cc) JustOpened, False)

closed :: Context -> Stream -> ClosedCode -> IO ()
closed ctx@Context{oddStreamTable, evenStreamTable} strm@Stream{streamNumber} cc = do
    if isServerInitiated streamNumber
        then deleteEven evenStreamTable streamNumber
        else deleteOdd oddStreamTable streamNumber
    setStreamState ctx strm (Closed cc) -- anyway

openOddStream :: Context -> StreamId -> FrameType -> IO Stream
openOddStream ctx@Context{oddStreamTable, peerSettings} sid ftyp = do
    ws <- initialWindowSize <$> readIORef peerSettings
    newstrm <- newOddStream sid ws
    when (ftyp == FrameHeaders || ftyp == FramePushPromise) $ opened ctx newstrm
    insertOdd oddStreamTable sid newstrm
    return newstrm

openEvenStream :: Context -> StreamId -> IO Stream
openEvenStream Context{evenStreamTable, peerSettings} sid = do
    ws <- initialWindowSize <$> readIORef peerSettings
    newstrm <- newEvenStream sid ws
    insertEven evenStreamTable sid newstrm
    return newstrm

openEvenStreamCache :: Context -> StreamId -> Method -> ByteString -> IO ()
openEvenStreamCache Context{evenStreamTable, peerSettings} sid method path = do
    ws <- initialWindowSize <$> readIORef peerSettings
    newstrm <- newEvenStream sid ws
    insertEvenCache evenStreamTable method path newstrm
