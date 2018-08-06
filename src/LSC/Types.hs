{-# LANGUAGE GADTs, DataKinds #-}

module LSC.Types where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Text (Text)

import Control.Monad.Reader
import Control.Monad.State
import Language.SMTLib2
import Language.SMTLib2.Pipe


data Netlist = Netlist [Gate] [Wire]
  deriving (Eq, Show)

data Wire = Wire 
  { source :: Gate
  , target :: Gate
  , wireIndex :: Index
  }
  deriving (Show)

instance Eq Wire where
  w == v = wireIndex w == wireIndex v

type Index = Int

data Gate = Gate
  { gateIdent :: Text
  , gateWires :: [Text]
  , gateIndex :: Index
  }
  deriving (Show)

instance Eq Gate where
  g == h = gateIndex g == gateIndex h


data Component = Component
  { componentPins :: Map Text Pin
  , componentDimensions :: (Integer, Integer)
  } deriving Show

data Pin = Pin Dir Port
  deriving Show

data Port = Port
  { portLayer :: Text
  , portRects :: [Rectangle]
  } deriving Show

type Rectangle = (Integer, Integer, Integer, Integer)

data Dir = In | Out | InOut
  deriving Show

data Technology = Technology
  { padDimensions :: (Integer, Integer)
  , wireWidth :: Integer
  , scaleFactor :: Double
  , components :: Map Text Component
  } deriving Show

defaultTechnology :: Technology
defaultTechnology = Technology (10^15, 10^15) 1 1 mempty

lookupDimensions :: Technology -> Gate -> (Integer, Integer)
lookupDimensions tech g = maybe (0, 0) id $ componentDimensions <$> Map.lookup (gateIdent g) (components tech)

type BootstrapT m = StateT Technology m
type Bootstrap = State Technology

bootstrap :: (Technology -> Technology) -> Bootstrap ()
bootstrap = modify

freeze :: Bootstrap () -> Technology
freeze bootstrapping = execState bootstrapping defaultTechnology

thaw :: Technology -> Bootstrap ()
thaw = put


type GnosticT m = ReaderT Technology m
type Gnostic = Reader Technology

runGnosticT :: GnosticT m r -> Technology -> m r
runGnosticT = runReaderT

gnostic :: Bootstrap () -> Gnostic r -> r
gnostic b a = a `runReader` freeze b


type LSC b = GnosticT (SMT b)

runLSC :: Bootstrap () -> LSC b r -> SMT b r
runLSC b a = a `runGnosticT` freeze b 

