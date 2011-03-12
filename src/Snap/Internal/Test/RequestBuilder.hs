
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Contains the combinators for the easy creation of Snap Requests 
module Snap.Internal.Test.RequestBuilder where

--------------------------------------------------------------------------------

import           Data.Bits ((.&.))
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as S
import qualified Data.ByteString.Base16 as B16
import           Data.CIByteString (CIByteString)
import           Control.Arrow (second)
import           Control.Monad (liftM)
import           Control.Monad.State (MonadState, StateT, put, execStateT)
import qualified Control.Monad.State as State
import           Control.Monad.Trans (MonadIO(..))
import           Data.Enumerator (runIteratee, run_, returnI)
import           Data.Enumerator.List (consume)
import           Data.IORef (IORef, newIORef, readIORef)
import qualified Data.Map as Map
import           System.Random (randoms, newStdGen)

--------------------------------------------------------------------------------

import           Snap.Internal.Http.Types hiding (setHeader)
import qualified Snap.Internal.Http.Types as H
import           Snap.Iteratee (enumBS)
import           Snap.Util.FileServe (defaultMimeTypes, fileType)

--------------------------------------------------------------------------------
-- | A type alias for Content-Lengths of Requests Bodies.
type ContentLength = Maybe Int

--------------------------------------------------------------------------------
-- | A type alias for Boundaries on Multipart Requests.
type Boundary      = ByteString

--------------------------------------------------------------------------------
-- | A type alias for File params, this are files that going to be sent through
-- a Multipart Request.
type FileParams    = Map.Map ByteString [(ByteString, ByteString)]


--------------------------------------------------------------------------------
-- | A Data type that will hold temporal values that later on will be used
-- to build Snap Request. Is really similar to the Request Data type, the only
-- difference is that it holds Content-Type of the Request, the Body as Text
-- and the File params.
data RequestProduct =
  RequestProduct {
    rqpMethod      :: Method
  , rqpParams      :: Params
  , rqpFileParams  :: FileParams
  , rqpBody        :: Maybe ByteString
  , rqpHeaders     :: Headers
  , rqpContentType :: ByteString
  , rqpIsSecure    :: !Bool
  , rqpURI         :: ByteString
  }
  deriving (Show)

--------------------------------------------------------------------------------
instance HasHeaders RequestProduct where
  headers = rqpHeaders
  updateHeaders f rqp = rqp { rqpHeaders = f (rqpHeaders rqp) }

--------------------------------------------------------------------------------
-- | Utility function that will help get the ByteString Request Body out of the 
-- the Request data type, that hold this internally as an @IORef SomeEnumerator@.
getBody :: Request -> IO ByteString
getBody request = do
  (SomeEnumerator enum) <- readIORef $ rqBody request
  S.concat `liftM` (runIteratee consume >>= run_ . enum)


--------------------------------------------------------------------------------
-- Request Body Content Builders
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- | This will recieve a @Params@ map and transform it into an encoded Query
-- String.
buildQueryString :: Params ->  -- ^ Parameters that will be turn into a QS
                    ByteString
buildQueryString = S.intercalate "&" . Map.foldWithKey helper []
  where 
    helper k vs acc = 
        (map (\v -> S.concat [urlEncode k, "=", urlEncode v]) vs) ++
        acc

--------------------------------------------------------------------------------
-- | This will recieve a @Params@ map, a @FileParams@ map and some randomly
-- generated boundaries to create a Multipart Request Body.
buildMultipartString :: Boundary ->   -- ^ Params Boundary
                        Boundary ->   -- ^ FileParams Boundary
                        Params ->     -- ^ Params map
                        FileParams -> -- ^ FileParams map
                        ByteString
buildMultipartString boundary fileBoundary params fileParams = 
    S.concat [ simpleParamsString
             , fileParamsString
             , S.concat ["--", boundary, "--"]]
  where
    crlf = "\r\n"
    contentTypeFor = fileType defaultMimeTypes . S.unpack

    ---------------------------------------------------------------------------- 
    -- Builds a Multipart Body for @Params@
    simpleParamsString = S.concat $ Map.foldWithKey spHelper [] params
    spHelper k vs acc  = (S.concat $ map (spPair k) vs) : acc
    spPair k v = 
        S.concat [ "--"
                 , boundary
                 , crlf
                 , "Content-Disposition: "
                 , "form-data; "
                 , "name=\""
                 , k
                 , "\""
                 , crlf
                 , crlf
                 , v
                 , crlf
                 ]
    
    ---------------------------------------------------------------------------- 
    -- Build a Multipart Body for @FileParams@
    fileParamsString = S.concat $ Map.foldWithKey fpHelper [] fileParams
    fpHelper k [(fname, fcontent)] acc = 
        (:acc) $ S.concat [
                   "--"
                 , boundary
                 , crlf
                 , "Content-Disposition: form-data; "
                 , "name=\""
                 , k
                 , "\"; filename=\""
                 , fname
                 , "\""
                 , crlf
                 , "Content-Type: "
                 , contentTypeFor fname
                 , crlf
                 , crlf
                 , fcontent
                 , crlf
                 ]
    fpHelper k vs acc = 
        (:acc) $ S.concat [
                   "--"
                 , boundary
                 , crlf
                 , "Content-Disposition: form-data; name=\""
                 , k
                 , "\""
                 , crlf
                 , "Content-Type: multipart/mixed; boundary="
                 , fileBoundary
                 , crlf
                 , crlf
                 ] `S.append`
                 S.concat (map (fpPair k) vs) `S.append`
                 S.concat ["--", fileBoundary, "--", crlf]
    fpPair k (fname, fcontent) = 
        S.concat [
          "--"
        , fileBoundary
        , crlf
        , "Content-Disposition: "
        , k
        , "; filename=\""
        , fname
        , "\""
        , crlf
        , "Content-Type: "
        , contentTypeFor fname
        , crlf
        , crlf
        , fcontent
        , crlf
        ]



--------------------------------------------------------------------------------
-- Builds an empty Request Body enumerator.
emptyRequestBody :: (MonadIO m) => m (IORef SomeEnumerator)
emptyRequestBody = liftIO . newIORef . SomeEnumerator $ returnI

--------------------------------------------------------------------------------
-- Builds a Request Body enumerator containing the given @ByteString@ content.
buildRequestBody :: (MonadIO m) => ByteString -> m (IORef SomeEnumerator)
buildRequestBody content = 
    liftIO . newIORef . SomeEnumerator $ enumBS content

--------------------------------------------------------------------------------
-- Builds a Random boundary that will be used for multipart Requests.
buildBoundary :: (MonadIO m) => m Boundary
buildBoundary = 
  liftM (S.append "snap-boundary-" . 
         B16.encode . 
         S.pack . 
         Prelude.map (toEnum . (.&. 255)) . 
         take 10 . 
         randoms) 
         (liftIO newStdGen)

--------------------------------------------------------------------------------
-- Request Procesors
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- Builds a Query String from the @RequestPart@.
processQueryString :: Method -> Params -> ByteString
processQueryString GET ps = buildQueryString ps
processQueryString _   _  = ""


--------------------------------------------------------------------------------
-- Builds a Request URI from a @RequestPart@, this function handles
-- adding a Query String to the URI if method is @GET@.
processRequestURI :: RequestProduct -> ByteString
processRequestURI rqp = 
    case (rqpMethod rqp) of
      GET 
        | (Map.null (rqpParams rqp)) -> (rqpURI rqp)
        | otherwise -> S.concat [ (rqpURI rqp)
                                , "?"
                                , buildQueryString (rqpParams rqp)
                                ]
      _   -> rqpURI rqp

--------------------------------------------------------------------------------
-- Builds the Request Headers from a @RequestPart@, the sole purpose of 
-- this function is to alter the Content-Type header to add a Boundary
-- if it is a multipart/form-data.
processRequestHeaders :: Maybe Boundary -> RequestProduct -> Headers
processRequestHeaders Nothing rqp = (rqpHeaders rqp)
processRequestHeaders (Just boundary) rqp 
  | (rqpContentType rqp) == "multipart/form-data"
    = H.setHeader 
        "Content-Type" 
        ("multipart/form-data; boundary=" `S.append` boundary)
        (rqpHeaders rqp)
  | otherwise = (rqpHeaders rqp)

--------------------------------------------------------------------------------
-- Given a @RequestProduct@, it gets all the info it can out of it to build 
-- a Request Body Enumerator, using the body content builder functions and the 
-- body enumerator builder functions. It takes into consideration the method
-- and the Content-Type of the Request to build the appropiate Request Body.
-- This function will return the Body enumerator, the Content Length and the 
-- Boundary used in case this is a Multipart Request.
processRequestBody :: (MonadIO m) => RequestProduct -> m ( IORef SomeEnumerator 
                                                         , ContentLength
                                                         , Maybe Boundary
                                                         )
processRequestBody rqp
  | (rqpMethod rqp) == POST && 
    (rqpContentType rqp) == "x-www-form-urlencoded"
    = do
      let qs = buildQueryString (rqpParams rqp)
      requestBody <- buildRequestBody qs
      return ( requestBody
             , Just $ S.length qs
             , Nothing
             )

  | (rqpMethod rqp) == POST &&
    (rqpContentType rqp) == "multipart/form-data"
    = do
      boundary     <- buildBoundary
      fileBoundary <- buildBoundary
      let multipartBody = buildMultipartString 
                            boundary
                            fileBoundary
                            (rqpParams rqp)
                            (rqpFileParams rqp)
      requestBody <- buildRequestBody multipartBody
      return ( requestBody
             , Just $ S.length multipartBody
             , Just $ boundary
             )

  | (rqpMethod rqp) == PUT
    = do 
      requestBody <- maybe emptyRequestBody buildRequestBody (rqpBody rqp)
      return ( requestBody
             , S.length `liftM` (rqpBody rqp)
             , Nothing
             )

  | otherwise = do 
    requestBody <- emptyRequestBody
    return (requestBody, Nothing, Nothing)

--------------------------------------------------------------------------------
-- | RequestBuilder is the Monad that will hold all the different combinators
-- to build in a simple way, all the Snap Request you will use for testing
-- suite of your Snap App.
newtype RequestBuilder m a
  = RequestBuilder (StateT RequestProduct m a)
  deriving (Monad, MonadIO)


--------------------------------------------------------------------------------
-- | This function will be the responsable of building Snap Request from the 
-- RequestBuilder combinators, this Request is the one that will be used to
-- perform Snap handlers.
buildRequest :: (MonadIO m) => RequestBuilder m () -> m Request
buildRequest (RequestBuilder m) = do 
  finalRqProduct <- execStateT m 
                      (RequestProduct GET 
                                      Map.empty 
                                      Map.empty
                                      Nothing 
                                      Map.empty
                                      "x-www-form-urlencoded"
                                      False
                                      "")
  (requestBody, contentLength, boundary)  <- processRequestBody finalRqProduct
  let requestURI     = processRequestURI finalRqProduct
  let requestHeaders = processRequestHeaders boundary finalRqProduct
  return $ Request {
        rqServerName    = "localhost"
      , rqServerPort    = 80
      , rqRemoteAddr    = "127.0.0.1"
      , rqRemotePort    = 80
      , rqLocalAddr     = "127.0.0.1"
      , rqLocalPort     = 80
      , rqLocalHostname = "localhost"
      , rqIsSecure      = (rqpIsSecure finalRqProduct)
      , rqHeaders       = requestHeaders
      , rqBody          = requestBody
      , rqContentLength = contentLength
      , rqMethod        = (rqpMethod finalRqProduct)
      , rqVersion       = (1,1)
      , rqCookies       = []
      , rqSnapletPath   = ""
      , rqPathInfo      = ""
      , rqContextPath   = ""
      , rqURI           = requestURI
      , rqQueryString   = processQueryString (rqpMethod finalRqProduct) 
                                             (rqpParams finalRqProduct)
      , rqParams        = (rqpParams finalRqProduct)
      }


--------------------------------------------------------------------------------
alterRequestProduct :: 
  (Monad m) => 
  (RequestProduct -> RequestProduct) -> 
  RequestBuilder m ()
alterRequestProduct fn = RequestBuilder $ State.get >>= put . fn

--------------------------------------------------------------------------------
-- Allows you to set the HTTP Method of a Request.
setMethod :: (Monad m) => Method -> RequestBuilder m ()
setMethod method = alterRequestProduct $ \rqp -> rqp { rqpMethod = method }


--------------------------------------------------------------------------------
-- Allows you to add a value to an existing parameter. This will not replace
-- the value but add one instead.
addParam :: (Monad m) => ByteString -> ByteString -> RequestBuilder m ()
addParam name value = alterRequestProduct helper
  where
    helper rqp = rqp { rqpParams = Map.alter (return . maybe [value] (value:)) name (rqpParams rqp) }


--------------------------------------------------------------------------------
-- Allows you to set a List of key-value pairs, this will be later used by the
-- Request as the parameters for the Snap Handler.
setParams :: (Monad m) => [(ByteString, ByteString)] -> RequestBuilder m ()
setParams params = alterRequestProduct $ \rqp -> rqp { rqpParams = params' }
  where
    params' = Map.fromList . map (second (:[])) $ params

--------------------------------------------------------------------------------
-- Allows you to set a List of key-value pairs, this will be later used by the
-- Request as the files given by the utility functions in the
-- @Snap.Util.FileUpload@ module.
setFileParams fparams = alterRequestProduct $ \rqp -> rqp { rqpFileParams = fparams' }
  where
    fparams' = Map.fromList . map (second (:[])) $ fparams

--------------------------------------------------------------------------------
-- Allows to set a body to the Request, this will only work as long as you use
-- the @PUT@ method. For @POST@ method the body will be created for you by the
-- API.
setRequestBody :: (Monad m) => ByteString -> RequestBuilder m ()
setRequestBody body = alterRequestProduct $ \rqp -> rqp { rqpBody = Just body }


--------------------------------------------------------------------------------
-- Allows to set a HTTP Header into the Snap Request.
--
-- Usage:
--
--     > response <- runHandler myHandler $ do
--     >               setHeader "Accepts" "application/json"
--     >               setHeader "X-Forwaded-For" "127.0.0.1"
--    
setHeader :: (Monad m) => CIByteString -> ByteString -> RequestBuilder m ()
setHeader name body = alterRequestProduct (H.setHeader name body)

--------------------------------------------------------------------------------
addHeader :: (Monad m) => CIByteString -> ByteString -> RequestBuilder m ()
addHeader name body = alterRequestProduct (H.addHeader name body)

--------------------------------------------------------------------------------
-- Sets the Content-Type to x-www-form-urlencoded, this is the default.
formUrlEncoded :: (Monad m) => RequestBuilder m ()
formUrlEncoded = do
    let contentType = "x-www-form-urlencoded"
    setHeader "Content-Type"  contentType 
    alterRequestProduct $ \rqp -> rqp { rqpContentType = contentType }

--------------------------------------------------------------------------------
-- Sets the Content-Type tp multipart/form-data, useful when submitting Files.
multipartEncoded :: (Monad m) => RequestBuilder m ()
multipartEncoded = do
    let contentType = "multipart/form-data"
    setHeader "Content-Type" contentType
    alterRequestProduct $ \rqp -> rqp { rqpContentType = contentType }

--------------------------------------------------------------------------------
-- Allows to set the Request as one using the HTTPS protocol.
useHttps :: (Monad m) => RequestBuilder m ()
useHttps = alterRequestProduct $ \rqp -> rqp { rqpIsSecure = True }

--------------------------------------------------------------------------------
-- Sets the URI that will address the Request in the different handlers.
setURI :: (Monad m) => ByteString -> RequestBuilder m ()
setURI uri = alterRequestProduct $ \rqp -> rqp { rqpURI = uri }

--------------------------------------------------------------------------------
-- Utility function that allows to create a GET request, using the parameters
-- given by the list of key-values. The Content-Type of the Request will be 
-- x-www-form-urlencoded.
--
-- Usage:
--
--     > response <- runHandler $ do
--     >               get "/posts" [("ordered", "1")]
--     >               setHeader "Accepts" "application/json"
--     >
--
get :: (Monad m) => ByteString -> 
                    [(ByteString, ByteString)] -> 
                    RequestBuilder m ()
get uri params = do
  formUrlEncoded
  setMethod GET
  setURI uri
  setParams params

--------------------------------------------------------------------------------
-- Allows the creation of POST requests, using the parameters provided by the 
-- list of key-values. The Content-Type of the Request will be
-- x-www-form-urlencoded.
--
-- Usage:
--
--     > response <- runHandler $ do
--     >               postUrlEncoded "/authenticate" [ ("login", "john@doe.com")
--     >                                              , ("password", "secret")
--     >                                              ]
--     >               setHeader "Accepts" "application/json"
--     >
--
postUrlEncoded :: (Monad m) => ByteString -> 
                               [(ByteString, ByteString)] -> 
                               RequestBuilder m ()
postUrlEncoded uri params = do
  formUrlEncoded
  setMethod POST
  setURI uri
  setParams params

--------------------------------------------------------------------------------
-- Allows the creation of POST request, that will include normal HTTP parameters
-- and File parameters, using the multipart/form-data Content-Type.
--
-- Usage:
--  
--     > photoContent <- ByteString.readFile "photo.jpg"
--     > response     <- runHandler $ do
--     >                   postMultipart "/picture/upload"
--     >                                 []
--     >                                 [("photo", ("photo.jpg", photoContent))]
--     >
postMultipart :: (Monad m) => ByteString -> 
                              [(ByteString, ByteString)] -> 
                              [(ByteString, (ByteString, ByteString))] -> 
                              RequestBuilder m ()
postMultipart uri params fileParams = do
  multipartEncoded
  setMethod POST
  setURI uri
  setParams params
  setFileParams fileParams

