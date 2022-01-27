{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
module Network.HTTP.Client.Connection
    ( connectionReadLine
    , connectionReadLineWith
    , connectionDropTillBlankLine
    , dummyConnection
    , openSocketConnection
    , openSocketConnectionSize
    , makeConnection
    , socketConnection
    , withSocket
    , strippedHostName
    ) where

import Data.ByteString (ByteString, empty)
import Data.IORef
import Control.Monad
import Network.HTTP.Client.Types
import Network.Socket (Socket, HostAddress)
import qualified Network.Socket as NS
import Network.Socket.ByteString (sendAll, recv)
import qualified Control.Exception as E
import qualified Data.ByteString as S
import Data.Word (Word8)
import Data.Function (fix)

connectionReadLine :: Connection -> IO ByteString
connectionReadLine conn = do
    bs <- connectionRead conn
    when (S.null bs) $ throwHttp IncompleteHeaders
    connectionReadLineWith conn bs

-- | Keep dropping input until a blank line is found.
connectionDropTillBlankLine :: Connection -> IO ()
connectionDropTillBlankLine conn = fix $ \loop -> do
    bs <- connectionReadLine conn
    unless (S.null bs) loop

connectionReadLineWith :: Connection -> ByteString -> IO ByteString
connectionReadLineWith conn bs0 =
    go bs0 id 0
  where
    go bs front total =
        case S.break (== charLF) bs of
            (_, "") -> do
                let total' = total + S.length bs
                when (total' > 4096) $ throwHttp OverlongHeaders
                bs' <- connectionRead conn
                when (S.null bs') $ throwHttp IncompleteHeaders
                go bs' (front . (bs:)) total'
            (x, S.drop 1 -> y) -> do
                unless (S.null y) $! connectionUnread conn y
                return $! killCR $! S.concat $! front [x]

charLF, charCR :: Word8
charLF = 10
charCR = 13

killCR :: ByteString -> ByteString
killCR bs
    | S.null bs = bs
    | S.last bs == charCR = S.init bs
    | otherwise = bs

-- | For testing
dummyConnection :: [ByteString] -- ^ input
                -> IO (Connection, IO [ByteString], IO [ByteString]) -- ^ conn, output, input
dummyConnection input0 = do
    iinput <- newIORef input0
    ioutput <- newIORef []
    return (Connection
        { connectionRead = atomicModifyIORef iinput $ \input ->
            case input of
                [] -> ([], empty)
                x:xs -> (xs, x)
        , connectionUnread = \x -> atomicModifyIORef iinput $ \input -> (x:input, ())
        , connectionWrite = \x -> atomicModifyIORef ioutput $ \output -> (output ++ [x], ())
        , connectionClose = return ()
        }, atomicModifyIORef ioutput $ \output -> ([], output), readIORef iinput)

-- | Create a new 'Connection' from a read, write, and close function.
--
-- @since 0.5.3
makeConnection :: IO ByteString -- ^ read
               -> (ByteString -> IO ()) -- ^ write
               -> IO () -- ^ close
               -> IO Connection
makeConnection r w c = do
    istack <- newIORef []

    -- it is necessary to make sure we never read from or write to
    -- already closed connection.
    closedVar <- newIORef False

    let close = do
          closed <- atomicModifyIORef closedVar (\closed -> (True, closed))
          unless closed $
            c

    _ <- mkWeakIORef istack close
    return $! Connection
        { connectionRead = do
            closed <- readIORef closedVar
            when closed $ throwHttp ConnectionClosed
            join $ atomicModifyIORef istack $ \stack ->
              case stack of
                  x:xs -> (xs, return x)
                  [] -> ([], r)

        , connectionUnread = \x -> do
            closed <- readIORef closedVar
            when closed $ throwHttp ConnectionClosed
            atomicModifyIORef istack $ \stack -> (x:stack, ())

        , connectionWrite = \x -> do
            closed <- readIORef closedVar
            when closed $ throwHttp ConnectionClosed
            w x

        , connectionClose = close
        }

-- | Create a new 'Connection' from a 'Socket'.
--
-- @since 0.5.3
socketConnection :: Socket
                 -> Int -- ^ chunk size
                 -> IO Connection
socketConnection socket chunksize = makeConnection
    (recv socket chunksize)
    (sendAll socket)
    (NS.close socket)

openSocketConnection :: (Socket -> IO ())
                     -> Maybe HostAddress
                     -> URIHostName String
                     -> Int -- ^ port
                     -> IO Connection
openSocketConnection f = openSocketConnectionSize f 8192

openSocketConnectionSize :: (Socket -> IO ())
                         -> Int -- ^ chunk size
                         -> Maybe HostAddress
                         -> URIHostName String
                         -> Int -- ^ port
                         -> IO Connection
openSocketConnectionSize tweakSocket chunksize hostAddress' host' port' =
    withSocket tweakSocket hostAddress' host' port' $ \ sock ->
        socketConnection sock chunksize

-- | strippedHostName takes a URI host name, as extracted
-- by 'Network.URI.regName', and strips square brackets
-- around IPv6 addresses.
--
-- The result is suitable for passing to services such as
-- name resolution ('Network.Socket.getAddr').
--
-- @since
strippedHostName :: String -> String
strippedHostName hostName =
    case hostName of
        '[':'v':_ -> hostName -- IPvFuture, no obvious way to deal with this
        '[':rest ->
            case break (== ']') rest of
                (ipv6, "]") -> ipv6
                _ -> hostName -- invalid host name
        _ -> hostName

withSocket :: (Socket -> IO ())
           -> Maybe HostAddress
           -> URIHostName String
           -> Int -- ^ port
           -> (Socket -> IO a)
           -> IO a
withSocket tweakSocket hostAddress' host' port' f = do
    let hints = NS.defaultHints { NS.addrSocketType = NS.Stream }
    addrs <- case hostAddress' of
        Nothing ->
            NS.getAddrInfo (Just hints) (Just $ unURIHostName host') (Just $ show port')
        Just ha ->
            return
                [NS.AddrInfo
                 { NS.addrFlags = []
                 , NS.addrFamily = NS.AF_INET
                 , NS.addrSocketType = NS.Stream
                 , NS.addrProtocol = 6 -- tcp
                 , NS.addrAddress = NS.SockAddrInet (toEnum port') ha
                 , NS.addrCanonName = Nothing
                 }]

    E.bracketOnError (firstSuccessful addrs $ openSocket tweakSocket) NS.close f

openSocket tweakSocket addr =
    E.bracketOnError
        (NS.socket (NS.addrFamily addr) (NS.addrSocketType addr)
                   (NS.addrProtocol addr))
        NS.close
        (\sock -> do
            NS.setSocketOption sock NS.NoDelay 1
            tweakSocket sock
            NS.connect sock (NS.addrAddress addr)
            return sock)

firstSuccessful :: [NS.AddrInfo] -> (NS.AddrInfo -> IO a) -> IO a
firstSuccessful []     _  = error "getAddrInfo returned empty list"
firstSuccessful (a:as) cb =
    cb a `E.catch` \(e :: E.IOException) ->
        case as of
            [] -> E.throwIO e
            _  -> firstSuccessful as cb
