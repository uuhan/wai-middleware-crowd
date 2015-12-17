{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
import           Data.String                    (fromString)
import qualified Data.Text                      as T
import           Network.HTTP.Client            (Manager, newManager)
import           Network.HTTP.Client.TLS        (tlsManagerSettings)
import           Network.HTTP.ReverseProxy      (ProxyDest (..), WaiProxyResponse (WPRProxyDest),
                                                 defaultOnExc, waiProxyTo)
import           Network.Wai                    (Application)
import           Network.Wai.Application.Static (defaultFileServerSettings,
                                                 staticApp, ssRedirectToIndex, ssAddTrailingSlash)
import           Network.Wai.Handler.Warp       (run)
import           Network.Wai.Middleware.Crowd
import           SimpleOptions
import           Web.ClientSession              (getKey)
import           Rdr2tls

data BasicSettings = BasicSettings
    { warpPort  :: Int
    , keyFile   :: FilePath
    , crowdRoot :: T.Text
    , age       :: Int
    , skipAuth  :: Bool
    , requireTls :: Bool
    }
    deriving Show

basicSettingsParser :: Parser BasicSettings
basicSettingsParser = BasicSettings
    <$> option auto
        ( long "listen-port"
       <> short 'p'
       <> metavar "LISTEN-PORT"
       <> help "Port to listen on for requests"
       <> value 3000 )
    <*> strOption
        ( long "key-file"
       <> short 'k'
       <> metavar "KEY-FILE"
       <> help "File containing the clientsession key"
       <> value "" )
    <*> (T.pack <$> strOption
        ( long "crowd-root"
       <> metavar "CROWD-ROOT"
       <> help "Base URL for the Crowd installation"
       <> value "" ))
    <*> option auto
        ( long "cookie-age"
       <> metavar "COOKIE-AGE"
       <> help "Number of seconds to keep auth cookie active"
       <> value 3600 )
    <*> switch
        ( long "skip-auth"
       <> help "Turn off Crowd authentication, useful for testing"
        )
    <*> switch
        ( long "require-tls"
       <> help "Require requests come in over a secure connection (determined via headers)"
        )

data Service = ServiceFiles FileServer
             | ServiceProxy ReverseProxy

data FileServer = FileServer
    { fsRoot :: FilePath
    , fsRedirectToIndex :: Bool
    , fsAddTrailingSlash :: Bool
    }

fileServerParser = FileServer
    <$> (argument str
         (metavar "ROOT-DIR" <> value "."))
    <*> switch
        ( long "redirect-to-index"
       <> help "Redirect to the actual index file, not leaving the URL containing the directory name"
        )
    <*> switch
        ( long "add-trailing-slash"
       <> help "Add a trailing slash to directory names"
        )

data ReverseProxy = ReverseProxy
    { rpHost :: String
    , rpPort :: Int
    }

reverseProxyParser :: Parser ReverseProxy
reverseProxyParser = ReverseProxy
    <$> (argument str (metavar "HOST"))
    <*> (argument auto (metavar "PORT"))

serviceToApp :: Manager -> Service -> IO Application
serviceToApp _ (ServiceFiles FileServer {..}) =
    return $ staticApp (defaultFileServerSettings $ fromString fsRoot)
        { ssRedirectToIndex = fsRedirectToIndex
        , ssAddTrailingSlash = fsAddTrailingSlash
        }
serviceToApp manager (ServiceProxy (ReverseProxy host port)) =
    return $ waiProxyTo
        (const $ return $ WPRProxyDest $ ProxyDest (fromString host) port)
        defaultOnExc
        manager

main :: IO ()
main = do
    (BasicSettings {..}, service) <- simpleOptions
        $(simpleVersion waiMiddlewareCrowdVersion)
        "wai-crowd - a Crowd-authenticated server"
        "Run a Crowd-authenticated file server or reverse proxy"
        basicSettingsParser $ do
            addCommand "file-server" "File server" ServiceFiles fileServerParser
            addCommand "reverse-proxy" "Reverse proxy" ServiceProxy reverseProxyParser
    manager <- newManager tlsManagerSettings
    let cs = (if null keyFile then id else setCrowdKey (getKey keyFile))
           $ (if T.null crowdRoot then id else setCrowdRoot crowdRoot)
           $ setCrowdManager (return manager)
           $ setCrowdAge age
           $ defaultCrowdSettings
    crowdMiddleware <- mkCrowdMiddleware cs
    app <- serviceToApp manager service
    putStrLn $ "Listening on port " ++ show warpPort
    run warpPort
        $ (if requireTls then rdr2tls else id)
          (if skipAuth then app else crowdMiddleware app)
