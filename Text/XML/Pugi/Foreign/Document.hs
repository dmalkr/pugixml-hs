{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE DeriveDataTypeable #-}
module Text.XML.Pugi.Foreign.Document where

import Control.Applicative
import Control.Monad
import Control.Exception

import Foreign.C
import Foreign.Ptr
import Foreign.ForeignPtr
import Foreign.Marshal.Utils

import Data.Typeable
import Data.IORef
import Data.Default.Class
import qualified Data.ByteString as S
import qualified Data.ByteString.Unsafe as S
import qualified Data.ByteString.Lazy as L

import Text.XML.Pugi.Foreign.Const
import Text.XML.Pugi.Foreign.Types
import System.IO.Unsafe

-- Document
foreign import ccall unsafe new_document :: IO (Ptr Document)
foreign import ccall unsafe "&delete_document" finalizerDocument
    :: FinalizerPtr Document
foreign import ccall unsafe reset_document_with :: Ptr Document -> Ptr Document -> IO ()

createDocument :: IO Document
createDocument = fmap Document $ newForeignPtr finalizerDocument =<< new_document

copyDocument :: Document -> IO Document
copyDocument (Document f) = withForeignPtr f $ \p -> do
    d <- new_document
    reset_document_with d p
    Document <$> newForeignPtr finalizerDocument d

-- Parsing
foreign import ccall unsafe delete_parse_result      :: ParseResult -> IO ()
foreign import ccall unsafe parse_is_success         :: ParseResult -> IO CInt
foreign import ccall unsafe parse_result_status      :: ParseResult -> IO ParseStatus
foreign import ccall unsafe parse_result_offset      :: ParseResult -> IO CLong
foreign import ccall unsafe parse_result_encoding    :: ParseResult -> IO Encoding
foreign import ccall unsafe parse_result_description :: ParseResult -> IO CString

foreign import ccall load_buffer :: Ptr Document -> Ptr a -> CSize -> ParseFlags -> Encoding -> IO ParseResult
foreign import ccall load_file   :: Ptr Document -> CString -> ParseFlags -> Encoding -> IO ParseResult

data ParseConfig = ParseConfig
    { parseFlags    :: ParseFlags
    , parseEncoding :: Encoding
    } deriving Show

instance Default ParseConfig where
    def = ParseConfig def def

data ParseException = ParseException
    { parseExceptionStatus     :: ParseStatus
    , parseExceptionOffset     :: CLong
    , parseExceptionEncoding   :: Encoding
    , parseExceptionDescripton :: String
    } deriving (Show, Typeable)

instance Exception ParseException

parseCommon :: (ForeignPtr Document -> a) -> (ParseException -> IO a)
            -> Ptr Document -> ParseResult -> IO a
parseCommon con err doc res = do
    ok <- parse_is_success res
    if toBool ok
        then con <$> newForeignPtr finalizerDocument doc
        else err =<< ParseException
            <$> parse_result_status res
            <*> parse_result_offset res
            <*> parse_result_encoding res
            <*> (parse_result_description res >>= peekCString)

parse :: ParseConfig -> S.ByteString -> Either ParseException Document
parse (ParseConfig flags enc) str = unsafePerformIO $ S.unsafeUseAsCStringLen str $ \(p,l) -> new_document >>= \doc ->
    bracket (load_buffer doc p (fromIntegral l) flags enc) delete_parse_result $
        parseCommon (Right . Document) (return . Left) doc

parseFile :: ParseConfig -> FilePath -> IO Document
parseFile (ParseConfig flags enc) path = withCString path $ \p -> new_document >>= \doc ->
    bracket (load_file doc p flags enc) delete_parse_result $
        parseCommon Document throwIO doc

-- format
foreign import ccall save_file :: Ptr Document -> CString -> CString -> FormatFlags -> Encoding -> IO CInt

type Writer = CString -> CSize -> IO ()
foreign import ccall "wrapper" wrap_writer :: Writer -> IO (FunPtr Writer)
foreign import ccall save_string :: Ptr Document -> FunPtr Writer -> CString -> FormatFlags -> Encoding -> IO ()

data PrettyConfig = PrettyConfig
    { prettyIndent   :: String
    , prettyFlags    :: FormatFlags
    , prettyEncoding :: Encoding
    } deriving Show

instance Default PrettyConfig where
    def = PrettyConfig "\t" def def

prettyFile :: PrettyConfig -> FilePath -> Document -> IO ()
prettyFile (PrettyConfig indent flags enc) path (Document doc) =
    withForeignPtr doc $ \d ->
    withCString indent $ \i ->
    withCString path   $ \p ->
    save_file d p i flags enc >>= \r ->
    unless (toBool r) (ioError $ userError "prettyFile failed.")

pretty :: PrettyConfig -> Document -> IO L.ByteString
pretty (PrettyConfig indent flags enc) (Document doc) = withForeignPtr doc $ \d -> withCString indent $ \i -> do
    ref <- newIORef (id :: [S.ByteString] -> [S.ByteString])
    let fun cs s = S.packCStringLen (cs, fromIntegral s) >>= \n -> modifyIORef ref (\a -> a . (n:))
    bracket (wrap_writer fun) freeHaskellFunPtr $ \fp ->
        save_string d fp i flags enc
    readIORef ref >>= \r -> return $ L.fromChunks (r [])
