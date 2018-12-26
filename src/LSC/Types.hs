{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LSC.Types where

import Data.Default
import Data.Function (on)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Semigroup
import Data.Text (Text)
import Data.Vector (Vector)

import Control.Monad.Codensity
import Control.Monad.Parallel (MonadFork(..), MonadParallel(..))
import qualified Control.Monad.Parallel as Par
import Control.Monad.Reader (ReaderT(..), Reader, runReader)
import qualified Control.Monad.Reader as Reader
import Control.Monad.State
import Control.Parallel.Strategies

import Data.Time.Clock.POSIX

import Data.SBV

import System.IO


data NetGraph = NetGraph
  { modelName  :: Text
  , modelPins  :: ([Text], [Text], [Text]) 
  , subModels  :: Map Text NetGraph
  , gateVector :: Vector Gate
  , netMapping :: Map Identifier Net
  } deriving Show

instance Semigroup NetGraph where
  net1 <> net2 = NetGraph
    (modelName net1)
    (modelPins net1)
    (subModels net1 `mappend` subModels net2)
    (gateVector net1)
    (netMapping net1)

instance Monoid NetGraph where
  mempty = NetGraph mempty mempty mempty mempty mempty
  mappend = (<>)


type Contact = (Identifier, Pin)

data Net = Net
  { netIdent :: Identifier
  , contacts :: Map Gate [Contact]
  , netIndex :: Index
  } deriving Show

instance Eq Net where
  w == v = netIndex w == netIndex v

instance Ord Net where
  w `compare` v = netIndex w `compare` netIndex v

instance Semigroup Net where
  Net i as k <> Net _ bs _ = Net i (Map.unionWith mappend as bs) k

instance Monoid Net where
  mempty = Net mempty mempty def
  mappend = (<>)


type Wire = Text

type Identifier = Text

type Index = Int

data Gate = Gate
  { gateIdent :: Identifier
  , gateWires :: Map Identifier Identifier
  , mapWires  :: Map Identifier Identifier
  , gateIndex :: Index
  } deriving Show

instance Eq Gate where
  g == h = gateIndex g == gateIndex h

instance Ord Gate where
  g `compare` h = gateIndex g `compare` gateIndex h

instance Default Gate where
  def = Gate "default" def def def


data Component = Component
  { componentPins :: Map Text Pin
  , componentDimensions :: (Integer, Integer)
  } deriving Show

data Pin = Pin
  { pinIdent :: Text
  , pinDir   :: Dir
  , pinPort  :: Port
  } deriving Show

instance Eq Pin where
  p == q = pinIdent p == pinIdent q

instance Ord Pin where
  compare = compare `on` pinIdent

instance Default Pin where
  def = Pin mempty In def


data Port = Port
  { portLayer :: Text
  , portRects :: [Rectangle]
  } deriving Show

instance Default Port where
  def = Port mempty [(0, 0, 0, 0)]


type Rectangle = (Integer, Integer, Integer, Integer)

data Dir = In | Out | InOut
  deriving (Eq, Show, Enum)


data Technology = Technology
  { padDimensions  :: (Integer, Integer)
  , wireResolution :: Int
  , wireWidth      :: Integer
  , scaleFactor    :: Double
  , components     :: Map Text Component
  , enableDebug    :: Bool
  } deriving Show

instance Default Technology where
  def = Technology (10^6, 10^6) 12 1 1 mempty True

lookupDimensions :: Gate -> Technology -> (Integer, Integer)
lookupDimensions g tech
  = maybe (0, 0) componentDimensions
  $ Map.lookup (gateIdent g) (components tech)

type BootstrapT m = StateT Technology m
type Bootstrap = State Technology

bootstrap :: (Technology -> Technology) -> Bootstrap ()
bootstrap = modify

freeze :: Bootstrap () -> Technology
freeze bootstrapping = execState bootstrapping def

thaw :: Technology -> Bootstrap ()
thaw = put


type GnosticT m = ReaderT Technology m
type Gnostic = Reader Technology

runGnosticT :: GnosticT m r -> Technology -> m r
runGnosticT = runReaderT

gnostic :: Bootstrap () -> Gnostic r -> r
gnostic b a = a `runReader` freeze b


type LSC = Codensity LST

newtype LST a = LST { unLST :: GnosticT Symbolic a }

instance Functor LST where
  fmap f (LST a) = LST (fmap f a)

instance Applicative LST where
  pure = LST . pure
  LST a <*> LST b = LST (a <*> b)

instance Monad LST where
  return = pure
  m >>= k = LST (unLST m >>= unLST . k)

instance MonadIO LST where
  liftIO = LST . liftIO

instance MonadFork LST where
  forkExec (LST m) = do
    fmap liftIO . liftIO . forkExec . runSMT . runGnosticT m =<< LST Reader.ask

instance MonadParallel LST where
  bindM2 f ma mb = do
    wb <- forkExec mb
    a <- ma
    b <- wb
    f a b

runLSC :: Bootstrap () -> LSC a -> IO a
runLSC b a = runSMT $ unLST (lowerCodensity a) `runGnosticT` freeze b

concLSC :: [LSC a] -> LSC [a]
concLSC = lift . Par.sequence . fmap lowerCodensity

conc :: NFData a => [a] -> [a]
conc ls = ls `using` parList rdeepseq

liftSMT :: Symbolic a -> LSC a
liftSMT = lift . LST . lift

ask :: LSC Technology
ask = lift $ LST Reader.ask

debug :: [String] -> LSC ()
debug msg = do
  enabled <- enableDebug <$> ask
  when enabled $ liftIO $ do
    timestamp <- show . round <$> getPOSIXTime
    hPutStrLn stderr $ unwords $ timestamp : "-" : msg


type Stage1 = Circuit2D Arboresence

type Arboresence = [((Net, Identifier), Path)]

data Circuit2D a = Circuit2D [(Gate, Path)] a
  deriving (Eq, Show)

newtype Path = Path [(Integer, Integer)]
  deriving (Eq, Show)

type SPath = [(SInteger, SInteger)]

