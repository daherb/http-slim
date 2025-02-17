{-# LANGUAGE ScopedTypeVariables, ForeignFunctionInterface #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Network.TCP
-- Copyright   :  See LICENSE file
-- License     :  BSD
--
-- Maintainer  :  Krasimir Angelov <kr.angelov@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (not tested)
--
-- Some utility functions for working with the Haskell @network@ package. Mostly
-- for internal use by the @Network.HTTP@ code.
--
-----------------------------------------------------------------------------
module Network.TCP
   ( Connection
   , openTCPConnection
   , socketConnection
   , isTCPConnectedTo
   , readBlock
   , readLine
   , writeAscii
   , writeBlock
   , close, closeOnEnd
   ) where

import Network.Socket
   ( Socket, SocketOption(KeepAlive)
   , SocketType(Stream), connect
   , shutdown, ShutdownCmd(..)
   , setSocketOption, getPeerName
   , socket, Family(AF_UNSPEC), defaultProtocol, getAddrInfo
   , defaultHints, addrFamily, withSocketsDo
   , addrSocketType, addrAddress
   )
import qualified Network.Socket as Socket ( sendBuf, recvBuf, close )
import Network.HTTP.Utils ( HttpError(..) )

import qualified OpenSSL.Session as SSL

import Control.Concurrent
import Control.Exception ( IOException, bracketOnError,
                           try, catch, bracket, throwIO )
import Control.Monad ( when )
import Data.Char  ( ord, toLower )
import Foreign
import Foreign.C.Types
import System.IO.Error ( isEOFError )
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BS ( ByteString(..), c2w )
import qualified Data.ByteString.Lazy as LBS
import GHC.IO.Buffer
import GHC.IO.Encoding hiding ( close )
import qualified GHC.IO.Encoding as Enc

-----------------------------------------------------------------
------------------ TCP Connections ------------------------------
-----------------------------------------------------------------

newtype Connection = Connection {getRef :: MVar Conn}

data Conn
 = MkConn { connSock      :: !Socket
          , connSSL       ::  Maybe SSL.SSL
          , connByteBuf   ::  Buffer Word8
          , connCharBuf   ::  Buffer Char
          , connChunkBits :: !Int
          , connHost      ::  String
          , connPort      :: !Int
          , connCloseEOF  ::  Bool -- True => close socket upon reaching end-of-stream.
          }
 | ConnClosed

readBlock :: Connection -> TextEncoding -> Int -> IO String
readBlock ref enc n =
  onNonClosedDo ref $ \conn ->
    catch (case enc of
             TextEncoding{mkTextDecoder=mkDecoder} -> do
                bracket mkDecoder Enc.close $ \decoder ->
                  fetch decoder conn n)
          (\e ->  if isEOFError e
                    then do
                      when (connCloseEOF conn) $ catch (closeQuick ref) (\(_ :: IOException) -> return ())
                      return (conn,"")
                    else throwIO e)
  where
    fetch decoder conn n
      | n > 0 = do
          bbuf <- if size > 0
                    then withBuffer bbuf $ \buf_ptr -> do
                           let ptr = buf_ptr `plusPtr` bufR bbuf
                           num <- case connSSL conn of
                                    Just ssl -> SSL.readPtr ssl ptr size
                                    Nothing  -> Socket.recvBuf (connSock conn) ptr size
                           return (bufferAdd num bbuf)
                    else return bbuf
          let bbufN = bbuf{bufR=bufL bbuf+min (n+connChunkBits conn) (bufferElems bbuf)}
          (progress,bbuf_,cbuf_) <- encode decoder bbufN cbuf

          (bbuf_,cbuf_,n_,b) <-
              let count = bufferElems bbufN-connChunkBits conn
              in case progress of
                   InputUnderflow  -> return (bbuf_,cbuf_,n-count,bufferElems bbuf_)
                   OutputUnderflow -> return (bbuf_,cbuf_,n-(count-bufferElems bbuf_),0)
                   InvalidSequence -> do (bbuf_,cbuf_) <- recover decoder bbuf_ cbuf_
                                         return (bbuf_,cbuf_,n-(count-bufferElems bbuf_),0)
          let len   = bufferElems cbuf_
              cbuf' = bufferRemove len cbuf_
          s1 <- withBuffer cbuf_ (peekArray len)
          bbuf' <- if bufL bbuf_ == bufR bbuf_
                     then if bufR bbufN == bufR bbuf
                            then return bbuf{bufL=0,bufR=0}
                            else slideContents (bbuf{bufL=bufR bbufN})
                     else slideContents (bbuf{bufL=bufL bbuf_})
          let conn' = conn{connByteBuf=bbuf'
                          ,connCharBuf=cbuf'
                          ,connChunkBits=b
                          }
          (conn,s2) <- fetch decoder conn' n_
          return (conn,s1++s2)
      | otherwise = return (conn,[])
      where
        bbuf = connByteBuf conn
        cbuf = connCharBuf conn
        size = min (n-bufferElems bbuf+connChunkBits conn) (bufferAvailable bbuf)


readLine :: Connection -> TextEncoding -> IO String
readLine ref enc =
  onNonClosedDo ref $ \conn ->
    catch (case enc of
             TextEncoding{mkTextDecoder=mkDecoder} -> do
                bracket mkDecoder Enc.close $ \decoder ->
                  fetch decoder conn)
          (\e ->
             if isEOFError e
               then do
                 when (connCloseEOF conn) $ catch (closeQuick ref) (\(_ :: IOException) -> return ())
                 return (conn,"")
               else throwIO e)
  where
    fetch decoder conn = do
      let bbuf = connByteBuf conn
          cbuf = connCharBuf conn
          size = bufferAvailable bbuf
      bbuf <- if size > 0
                then withBuffer bbuf $ \buf_ptr -> do
                       let ptr = buf_ptr `plusPtr` bufR bbuf
                       num <- case connSSL conn of
                                Just ssl -> SSL.readPtr ssl ptr size
                                Nothing  -> Socket.recvBuf (connSock conn) ptr size
                       return (bufferAdd num bbuf)
                else return bbuf
      if bufferElems bbuf == connChunkBits conn
        then return (conn, [])
        else do let start = bufL bbuf+connChunkBits conn
                (bbufNL,nl) <- scanNL start bbuf{bufL=start}
                (progress,bbuf_,cbuf_) <- encode decoder bbufNL cbuf
                (bbuf_,cbuf_) <- case progress of
                                   InvalidSequence -> recover decoder bbuf_ cbuf_
                                   _               -> return (bbuf_,cbuf_)
                let len   = bufferElems cbuf_
                    cbuf' = bufferRemove len cbuf_
                s1 <- withBuffer cbuf_ (peekArray len)
                bbuf' <- if connChunkBits conn+(bufR bbuf-bufR bbufNL)+bufferElems bbuf_ <= 0
                           then return bbuf_{bufL=0,bufR=0}
                           else slideContents' start (bufR bbufNL-bufferElems bbuf_) bbuf
                let conn' = conn{connByteBuf=bbuf'
                                ,connCharBuf=cbuf'
                                }
                if nl && bufferElems bbuf_ == 0
                  then return (conn', s1)
                  else do (conn,s2) <- fetch decoder conn'
                          return (conn,s1++s2)

    scanNL i bbuf
      | i >= bufR bbuf =
          return (bbuf, False)
      | otherwise      = do
          c <- withBuffer bbuf $ \ptr ->
                 peekElemOff ptr i
          if c == fromIntegral (ord '\n')
            then return (bbuf{bufR=i+1}, True)
            else scanNL (i+1) bbuf

slideContents' :: Int -> Int -> Buffer Word8 -> IO (Buffer Word8)
slideContents' start end buf@Buffer{ bufR=r, bufRaw=raw } = do
  let elems = r - end
  withRawBuffer raw $ \p ->
      do _ <- memmove (p `plusPtr` start) (p `plusPtr` end) (fromIntegral elems)
         return ()
  return buf{ bufR=start+elems }

foreign import ccall unsafe "memmove"
   memmove :: Ptr a -> Ptr a -> CSize -> IO (Ptr a)

writeAscii :: Connection -> String -> IO ()
writeAscii ref s =
  onNonClosedDo ref $ \conn ->
    send conn s
  where
    send conn cs =
      let bbuf = connByteBuf conn
      in if null cs
           then return (conn,())
           else do (bbuf_,cs) <- pokeElems bbuf cs
                   let n = bufferElems bbuf_
                   withBuffer bbuf_ $ \ptr -> do
                     case connSSL conn of
                       Just ssl -> SSL.writePtr ssl ptr n
                       Nothing  -> do _ <- Socket.sendBuf (connSock conn) ptr n
                                      return ()
                   let bbuf' = bufferRemove n bbuf_
                       conn' = conn{connByteBuf=bbuf'}
                   send conn' cs
      where
        pokeElems bbuf cs
          | null cs || isFullCharBuffer bbuf = return (bbuf,cs)
        pokeElems bbuf (c:cs)  = do
          withBuffer bbuf $ \ptr ->
            pokeElemOff ptr (bufR bbuf) (BS.c2w c)
          pokeElems (bufferAdd 1 bbuf) cs    

writeBlock :: Connection -> LBS.ByteString -> IO ()
writeBlock ref lbs =
  onNonClosedDo ref $ \conn -> do
    mapM_ (send conn) (LBS.toChunks lbs)
    return (conn,())
  where
    send conn (BS.PS fptr offs len) =
      withForeignPtr fptr $ \ptr ->
        case connSSL conn of
          Just ssl -> SSL.writePtr ssl (ptr `plusPtr` offs) len
          Nothing  -> do _ <- Socket.sendBuf (connSock conn) (ptr `plusPtr` offs) len
                         return ()

-- Closes a Connection.  Connection will no longer
-- allow any of the other functions.  Notice that a Connection may close
-- at any time before a call to this function. This function is idempotent.
-- (I think the behaviour here is TCP specific)
close :: Connection -> IO ()
close c = closeIt c null True

-- Closes a Connection without munching the rest of the stream.
closeQuick :: Connection -> IO ()
closeQuick c = closeIt c null False

closeOnEnd :: Connection -> Bool -> IO ()
closeOnEnd c f = closeEOF c f

-- Add a "persistent" option?  Current persistent is default.
-- Use "Result" type for synchronous exception reporting?
openTCPConnection :: Maybe SSL.SSLContext -> String -> Int -> IO Connection
openTCPConnection mb_ctx host port = do
    -- HACK: uri is sometimes obtained by calling Network.URI.uriRegName, and this includes
    -- the surrounding square brackets for an RFC 2732 host like [::1]. It's not clear whether
    -- it should, or whether all call sites should be using something different instead, but
    -- the simplest short-term fix is to strip any surrounding square brackets here.
    -- It shouldn't affect any as this is the only situation they can occur - see RFC 3986.
    let fixedHost =
         case host of
            '[':(rest@(c:_)) | last rest == ']'
              -> if c == 'v' || c == 'V'
                     then error $ "Unsupported post-IPv6 address " ++ host
                     else init rest
            '/':'/':host' -> host'
            _ -> host

    -- use withSocketsDo here in case the caller hasn't used it, which would make getAddrInfo fail on Windows
    -- although withSocketsDo is supposed to wrap the entire program, in practice it is safe to use it locally
    -- like this as it just does a once-only installation of a shutdown handler to run at program exit,
    -- rather than actually shutting down after the action
    addrinfos <- withSocketsDo $ getAddrInfo (Just $ defaultHints { addrFamily = AF_UNSPEC, addrSocketType = Stream }) (Just fixedHost) (Just . show $ port)

    let
      connectAddrInfo a = bracketOnError
        (socket (addrFamily a) Stream defaultProtocol) -- acquire
        Socket.close                                   -- release
        (\s -> do
            setSocketOption s KeepAlive 1
            connect s (addrAddress a)
            mb_ssl <- case mb_ctx of
                        Nothing   -> return Nothing
                        Just ctxt -> do ssl <- SSL.connection ctxt s
                                        SSL.connect ssl
                                        return (Just ssl)
            socketConnection fixedHost port s mb_ssl)

      -- try multiple addresses; return Just connected socket or Nothing
      tryAddrInfos [] = return Nothing
      tryAddrInfos (h:t) =
        let next = \(_ :: IOException) -> tryAddrInfos t
        in  try (connectAddrInfo h) >>= either next (return . Just)

    case addrinfos of
        [] -> fail "openTCPConnection: getAddrInfo returned no address information"

        -- single AddrInfo; call connectAddrInfo directly so that specific
        -- exception is thrown in event of failure
        [ai] -> connectAddrInfo ai `catch` (\e -> fail $
                  "openTCPConnection: failed to connect to "
                  ++ show (addrAddress ai) ++ ": " ++ show (e :: IOException))

        -- multiple AddrInfos; try each until we get a connection, or run out
        ais ->
          let
            err = fail $ "openTCPConnection: failed to connect; tried addresses: "
                         ++ show (fmap addrAddress ais)
          in tryAddrInfos ais >>= maybe err return

-- | @socketConnection@, like @openConnection@ but using a pre-existing 'Socket'.
socketConnection :: String
                 -> Int
                 -> Socket
                 -> Maybe SSL.SSL
                 -> IO Connection
socketConnection host port sock mb_ssl = do
  bbuf <- newByteBuffer 256 ReadBuffer
  cbuf <- newCharBuffer 256 WriteBuffer
  let conn = MkConn
         { connSock     = sock
         , connSSL      = mb_ssl
         , connByteBuf  = bbuf
         , connCharBuf  = cbuf
         , connChunkBits= 0
         , connHost     = host
         , connPort     = port
         , connCloseEOF = False
         }
  v <- newMVar conn
  return (Connection v)

closeConnection :: Connection -> IO Bool -> IO ()
closeConnection ref readL = do
    -- won't hold onto the lock for the duration
    -- we are draining it...ToDo: have Connection
    -- into a shutting-down state so that other
    -- threads will simply back off if/when attempting
    -- to also close it.
  c <- readMVar (getRef ref)
  closeConn c
  modifyMVar_ (getRef ref) (\ _ -> return ConnClosed)
 where
   -- Be kind to peer & close gracefully.
  closeConn ConnClosed = return ()
  closeConn conn       = do
    catch (do case connSSL conn of
                Just ssl -> SSL.shutdown ssl SSL.Unidirectional
                Nothing  -> return ()
              shutdown (connSock conn) ShutdownSend
              suck readL
              shutdown (connSock conn) ShutdownReceive)
          (\(_ :: IOException) -> return ())
    Socket.close (connSock conn)

  suck :: IO Bool -> IO ()
  suck rd = do
    f <- rd
    if f then return () else suck rd

isTCPConnectedTo :: Connection -> String -> Int -> IO Bool
isTCPConnectedTo conn host port = do
   v <- readMVar (getRef conn)
   case v of
     ConnClosed -> return False
     _
      | map toLower (connHost v) == map toLower host &&
        connPort v == port ->
          catch (getPeerName (connSock v) >> return True) (\(_ :: IOException) -> return False)
      | otherwise -> return False

closeIt :: Connection -> (String -> Bool) -> Bool -> IO ()
closeIt c p b = do
   closeConnection c (if b
                      then catch (fmap p (readLine c latin1)) (\(e :: HttpError) -> return True)
                      else return True)

closeEOF :: Connection -> Bool -> IO ()
closeEOF c flg = modifyMVar_ (getRef c) (\co -> return co{connCloseEOF=flg})

onNonClosedDo :: Connection -> (Conn -> IO (Conn, b)) -> IO b
onNonClosedDo c act = modifyMVar (getRef c) $ \conn -> do
  case conn of
    ConnClosed -> throwIO ErrorClosed
    _          -> act conn
