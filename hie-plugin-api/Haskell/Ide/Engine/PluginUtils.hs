{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
module Haskell.Ide.Engine.PluginUtils
  (
    mapEithers
  , pluginGetFile
  , pluginGetFileResponse
  , diffText
  , srcSpan2Range
  , srcSpan2Loc
  , reverseMapFile
  , fileInfo
  , realSrcSpan2Range
  , canonicalizeUri
  , newRangeToOld
  , oldRangeToNew
  , newPosToOld
  , oldPosToNew
  , unPos
  , toPos
  ) where

import           Control.Monad.IO.Class
import           Control.Monad.Trans.Except
import           Data.Aeson
import           Data.Algorithm.Diff
import           Data.Algorithm.DiffOutput
import qualified Data.HashMap.Strict                   as H
import           Data.Monoid
import qualified Data.Text                             as T
import           FastString
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.ArtifactMap
import qualified Language.Haskell.LSP.Types            as J
import           Prelude                               hiding (log)
import           SrcLoc
import           System.Directory
import           System.FilePath

-- ---------------------------------------------------------------------

canonicalizeUri :: MonadIO m => Uri -> m Uri
canonicalizeUri uri =
  case uriToFilePath uri of
    Nothing -> return uri
    Just fp -> do
      fp' <- liftIO $ canonicalizePath fp
      return $ filePathToUri fp'

newRangeToOld :: CachedModule -> Range -> Maybe Range
newRangeToOld cm (Range start end) = do
  start' <- newPosToOld cm start
  end'   <- newPosToOld cm end
  return (Range start' end')

oldRangeToNew :: CachedModule -> Range -> Maybe Range
oldRangeToNew cm (Range start end) = do
  start' <- oldPosToNew cm start
  end'   <- oldPosToNew cm end
  return (Range start' end')

getRealSrcSpan :: SrcSpan -> Either T.Text RealSrcSpan
getRealSrcSpan (RealSrcSpan r)   = Right r
getRealSrcSpan (UnhelpfulSpan x) = Left $ T.pack $ unpackFS x

realSrcSpan2Range :: RealSrcSpan -> Range
realSrcSpan2Range = uncurry Range . unpackRealSrcSpan

srcSpan2Range :: SrcSpan -> Either T.Text Range
srcSpan2Range spn =
  realSrcSpan2Range <$> getRealSrcSpan spn

reverseMapFile :: MonadIO m => (FilePath -> FilePath) -> FilePath -> m FilePath
reverseMapFile rfm fp = do
  fp' <- liftIO $ canonicalizePath fp
  debugm $ "reverseMapFile: mapped file is " ++ fp'
  let orig = rfm fp'
  debugm $ "reverseMapFile: original is " ++ orig
  orig' <- liftIO $ canonicalizePath orig
  debugm $ "reverseMapFile: Canonicalized original is " ++ orig
  return orig'

srcSpan2Loc :: (MonadIO m) => (FilePath -> FilePath) -> SrcSpan -> m (Either T.Text Location)
srcSpan2Loc revMapp spn = runExceptT $ do
  let
    foo :: (Monad m) => Either T.Text RealSrcSpan -> ExceptT T.Text m RealSrcSpan
    foo (Left  e) = throwE e
    foo (Right v) = pure v
  rspan <- foo $ getRealSrcSpan spn
  let fp = unpackFS $ srcSpanFile rspan
  debugm $ "srcSpan2Loc: mapped file is " ++ fp
  file <- reverseMapFile revMapp fp
  debugm $ "srcSpan2Loc: Original file is " ++ file
  return $ Location (filePathToUri file) (realSrcSpan2Range rspan)

-- ---------------------------------------------------------------------

-- | Helper function that extracts a filepath from a Uri if the Uri
-- is well formed (i.e. begins with a file:// )
-- fails with an IdeResultFail otherwise
pluginGetFile
  :: Monad m
  => T.Text -> Uri -> (FilePath -> m (IdeResult a)) -> m (IdeResult a)
pluginGetFile name uri f =
  case uriToFilePath uri of
    Just file -> f file
    Nothing -> return $ IdeResultFail (IdeError PluginError
                 (name <> "Couldn't resolve uri" <> getUri uri) Null)

-- | @pluginGetFile but for IdeResponse - use with IdeM
pluginGetFileResponse
  :: Monad m
  => T.Text -> Uri -> (FilePath -> m (IdeResponse a)) -> m (IdeResponse a)
pluginGetFileResponse name uri f =
  case uriToFilePath uri of
    Just file -> f file
    Nothing -> return $ IdeResponseFail (IdeError PluginError
                (name <> "Couldn't resolve uri" <> getUri uri) Null)

-- ---------------------------------------------------------------------
-- courtesy of http://stackoverflow.com/questions/19891061/mapeithers-function-in-haskell
mapEithers :: (a -> Either b c) -> [a] -> Either b [c]
mapEithers f (x:xs) = case mapEithers f xs of
                        Left err -> Left err
                        Right ys -> case f x of
                                      Left err -> Left err
                                      Right y  -> Right (y:ys)
mapEithers _ _ = Right []

-- ---------------------------------------------------------------------

-- |Generate a 'WorkspaceEdit' value from a pair of source Text
diffText :: (Uri,T.Text) -> T.Text -> WorkspaceEdit
diffText (f,fText) f2Text = WorkspaceEdit (Just h) Nothing
  where
    d = getGroupedDiff (lines $ T.unpack fText) (lines $ T.unpack f2Text)
    diffOps = diffToLineRanges d
    r = map diffOperationToTextEdit diffOps
    diff = J.List r
    h = H.singleton f diff

    diffOperationToTextEdit :: DiffOperation LineRange -> J.TextEdit
    diffOperationToTextEdit (Change fm to) = J.TextEdit range nt
      where
        range = calcRange fm
        nt = T.pack $ init $ unlines $ lrContents to

    diffOperationToTextEdit (Deletion fm _) = J.TextEdit range ""
      where
        range = calcRange fm

    diffOperationToTextEdit (Addition fm l) = J.TextEdit range nt
    -- fm has a range wrt to the changed file, which starts in the current file at l
    -- So the range has to be shifted to start at l
      where
        range = J.Range (J.Position (l' - 1) 0)
                        (J.Position (l' - 1) 0)
        l' = max l sl -- Needed to add at the end of the file
        sl = fst $ lrNumbers fm
        nt = T.pack $ unlines $ lrContents fm


    calcRange fm = J.Range s e
      where
        sl = fst $ lrNumbers fm
        sc = 0
        s = J.Position (sl - 1) sc -- Note: zero-based lines
        el = snd $ lrNumbers fm
        ec = length $ last $ lrContents fm
        e = J.Position (el - 1) ec  -- Note: zero-based lines

-- ---------------------------------------------------------------------

-- | Returns the directory and file name
fileInfo :: T.Text -> (FilePath,FilePath)
fileInfo tfileName =
  let sfileName = T.unpack tfileName
      dir = takeDirectory sfileName
  in (dir,sfileName)

-- ---------------------------------------------------------------------
