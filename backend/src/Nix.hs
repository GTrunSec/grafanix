module Nix
  ( drvPath
  , pkgPath
  , depGraph
  )
where

import           Control.Error                  ( Script
                                                , scriptIO
                                                )
import           Data.Attoparsec.Text           ( Parser
                                                , parseOnly
                                                )
import qualified Data.ByteString.Lazy.Char8    as ByteString.Lazy
import qualified Data.ByteString.Lazy.Builder  as ByteString.Builder
import           Data.Hashable                  ( Hashable )
import           Data.IORef                     ( atomicModifyIORef )
import           Data.LruCache                  ( insert
                                                , lookup
                                                )
import           Data.LruCache.IO               ( LruHandle(..) )
import qualified Data.Map                      as Map
import qualified Data.Vector                   as Vector
import           Data.Text                      ( isSuffixOf
                                                , unwords
                                                )

import           System.Process.Typed
import           Protolude

import           Config
import qualified Parser
import           Types

decolor :: ByteString.Lazy.ByteString -> ByteString.Lazy.ByteString
decolor = ByteString.Builder.toLazyByteString . go mempty
 where
  go
    :: ByteString.Builder.Builder
    -> ByteString.Lazy.ByteString
    -> ByteString.Builder.Builder
  go acc "" = acc
  go acc string =
    let esc                = '\x1b'
        colorSequenceStart = "\x1b["
        (text, colored)    = ByteString.Lazy.span (/= esc) string
        -- Attempt to strip a color sequence
        rest = case ByteString.Lazy.stripPrefix colorSequenceStart colored of
          Just x ->
            -- All color sequences look like this: ESC[#(;#)m
            ByteString.Lazy.drop 1 . ByteString.Lazy.dropWhile (/= 'm') $ x
          Nothing ->
            -- Just skip ESC otherwise
            ByteString.Lazy.dropWhile (== esc) colored
    in  go (acc <> ByteString.Builder.lazyByteString text) rest

run :: Text -> [Text] -> Script Text
run cmd args = do
  putText cmdline
  let procConfig =
        setStdin closed $ setStdout byteStringOutput $ setStderr closed $ proc
          (toS cmd)
          (map toS args)
  (exitCode, out, err) <- readProcess procConfig
  if exitCode == ExitSuccess
    then return . toS $ decolor out
    else
      let message = "Command '" <> cmdline <> "' failed with:\n" <> toS err
      in  throwError message
  where cmdline = cmd <> " " <> unwords args

cached
  :: (Hashable k, Ord k) => LruHandle k v -> (k -> Script v) -> k -> Script v
cached (LruHandle ref) script k = do
  cachedValue <- scriptIO $ atomicModifyIORef ref $ \cache ->
    case lookup k cache of
      Nothing          -> (cache, Nothing)
      Just (v, cache') -> (cache', Just v)
  case cachedValue of
    Just v  -> return v
    Nothing -> do
      v <- script k
      scriptIO $ atomicModifyIORef ref $ \cache -> (insert k v cache, ())
      return v

parse :: Parser a -> Text -> Script a
parse parser text = case parseOnly parser text of
  Right a   -> return a
  Left  err -> throwError . toS $ err

drvPath :: Text -> App Text
drvPath pkgName = do
  nixpkgs <- asks (nixpkgsPath . config)
  out     <- lift $ run "nix-instantiate" [nixpkgs, "--attr", pkgName]
  lift $ parse Parser.nixPath out

pkgPath :: Text -> App Text
pkgPath pkgName = do
  nixpkgs <- asks (nixpkgsPath . config)
  out <- lift $ run "nix-build" [nixpkgs, "--attr", pkgName, "--no-out-link"]
  lift $ parse Parser.nixPath out

sizeAndClosureSize :: Text -> Script (Int, Int)
sizeAndClosureSize path = do
  out <- run "nix" ["path-info", "--size", "--closure-size", path]
  parse Parser.sizeAndClosureSize out

whyDepends :: (Text, Text) -> Script [Why]
whyDepends (src, dest) = do
  out <- run "nix" ["why-depends", src, dest]
  parse Parser.whyDepends out

depGraph :: Text -> App (DepGraph, DepInfo)
depGraph path = do
  out   <- lift $ run "nix-store" ["--query", "--graph", path]
  graph <- lift $ parse Parser.depGraph out
  let depNames = nodes graph
  depInfos <- mapM (getInfo path) depNames
  let info = Map.fromList . Vector.toList $ Vector.zip depNames depInfos
  return (graph, info)
 where
  getInfo :: Text -> Text -> App Dep
  getInfo parent child = do
    sizeCache           <- asks sizeCache
    whyCache            <- asks whyCache
    (size, closureSize) <- lift $ cached sizeCache sizeAndClosureSize child
    (sha , name       ) <- lift $ parse Parser.hashAndName child
    why                 <- if buildDeps
      then return []
      else lift $ cached whyCache whyDepends (parent, child)
    return Dep { .. }

  buildDeps :: Bool
  buildDeps = ".drv" `isSuffixOf` path
