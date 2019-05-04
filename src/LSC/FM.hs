{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}

module LSC.FM where

import Control.Lens
import Control.Monad
import Control.Monad.Reader
import Control.Monad.ST
import Data.Foldable
import Data.Maybe
import Data.Monoid
import Data.HashTable.ST.Cuckoo (HashTable)
import qualified Data.HashTable.ST.Cuckoo as H
import qualified Data.HashTable.Class as HC
import Data.IntSet hiding (filter, findMax, foldl', toList, null)
import qualified Data.IntSet as Set
import Data.IntMap (IntMap, fromListWith, findMax, unionWith, insertWith, adjust, assocs)
import qualified Data.IntMap as Map
import Data.Ratio
import Data.STRef
import Data.Tuple
import Data.Vector (Vector, unsafeFreeze, unsafeThaw, thaw, (!), generate)
import Data.Vector.Mutable hiding (swap, length, set, move, null, new)
import Prelude hiding (replicate, length, read)


type FM s = ReaderT (STRef s (Heu s)) (ST s)

balanceFactor :: Rational
balanceFactor = 1 % 2


data Gain s a = Gain
  (STRef s IntSet)      -- track existing gains
  (HashTable s a Int)   -- gains indexed by node
  (HashTable s Int [a]) -- nodes indexed by gain


data Move
  = Move Int Int -- Move Gain Cell
  deriving Show


type Partition = P IntSet

data P a = P !a !a

unP :: P a -> (a, a)
unP (P a b) = (a, b)

instance Eq a => Eq (P a) where
  P a _ == P b _ = a == b

instance Semigroup a => Semigroup (P a) where
  P a b <> P c d = P (a <> c) (b <> d)

instance Monoid a => Monoid (P a) where
  mempty = P mempty mempty
  mappend = (<>)

instance Show a => Show (P a) where
  show (P a b) = "<"++ show a ++", "++ show b ++">"

move :: Int -> Partition -> Partition
move c (P a b) | member c a = P (delete c a) (insert c b)
move c (P a b) = P (insert c a) (delete c b)

partitionBalance :: Partition -> Int
partitionBalance (P a b) = abs $ size a - size b


data Heu s = Heu
  { _partitioning :: Partition
  , _gains        :: Gain s Int
  , _freeCells    :: IntSet
  , _moves        :: [(Move, Partition)]
  , _iterations   :: Int
  }

makeFieldsNoPrefix ''Heu


evalFM :: FM s a -> ST s a
evalFM = runFM

runFM :: FM s a -> ST s a
runFM f = do
  gmax <- newSTRef mempty
  (u, m) <- (,) <$> H.new <*> H.new
  r <- newSTRef $ Heu mempty (Gain gmax u m) mempty mempty 0
  runReaderT f r


update :: Simple Setter (Heu s) a -> (a -> a) -> FM s ()
update v f = do
  r <- modifySTRef <$> ask
  lift $ r $ v %~ f

value :: Getter (Heu s) a -> FM s a
value v = view v <$> getState

getState :: FM s (Heu s)
getState = lift . readSTRef =<< ask


type NetArray  = Vector IntSet
type CellArray = Vector IntSet

type V = CellArray
type E = NetArray


computeG :: FM s (Int, Partition)
computeG = do
  p <- value partitioning
  (_, g, h) <- foldl' accum (0, 0, p) <$> value moves
  pure (g, h)
  where
    accum :: (Int, Int, Partition) -> (Move, Partition) -> (Int, Int, Partition)
    accum (gmax, g, _) (Move gc c, q)
      | g + gc > gmax
      = (g + gc, g + gc, q)
    accum (gmax, g, p) (Move gc c, q)
      | g + gc == gmax
      , partitionBalance p > partitionBalance q
      = (gmax, g + gc, q)
    accum (gmax, g, p) (Move gc c, _)
      = (gmax, g + gc, p)


fiducciaMattheyses (v, e) = do
  initialPartitioning v
  bipartition (v, e)


bipartition :: (V, E) -> FM s Partition
bipartition (v, e) = do
  initialFreeCells v
  initialGains (v, e)
  update moves $ const mempty
  update iterations succ
  processCell (v, e)
  (g, p) <- computeG
  update partitioning $ const p
  it <- value iterations
  if it >= 3 || g <= 0
    then pure p
    else bipartition (v, e)


processCell :: (V, E) -> FM s ()
processCell (v, e) = do
  ci <- selectBaseCell v
  for_ ci $ \ i -> do
    lockCell i
    updateGains (v, e) i
    processCell (v, e)


lockCell :: Int -> FM s ()
lockCell c = do
  update freeCells $ delete c
  lift . removeGain c =<< value gains


moveCell :: Int -> FM s ()
moveCell c = do
  Gain _ u _ <- value gains
  v <- lift $ H.lookup u c
  for_ v $ \ g -> do
    update partitioning $ move c
    p <- value partitioning
    update moves ((Move g c, p) :)


selectBaseCell :: V -> FM s (Maybe Int)
selectBaseCell v = do
  g <- value gains
  h <- getState
  (i, xs) <- lift $ maxGain g
  pure $ listToMaybe [ x | x <- join $ maybeToList xs, balanceCriterion h i x ]


updateGains :: (V, E) -> Int -> FM s ()
updateGains (v, e) c = do
  p <- value partitioning
  let f = fromBlock p c e
  let t = toBlock p c e
  free <- value freeCells
  moveCell c
  for_ (elems $ v ! c) $ \ n -> do
    when (size (t n) == 0) $ sequence_ $ incrementGain <$> elems (f n `intersection` free)
    when (size (t n) == 1) $ sequence_ $ decrementGain <$> elems (t n `intersection` free)
    when (size (f n) == succ 0) $ sequence_ $ decrementGain <$> elems (t n `intersection` free)
    when (size (f n) == succ 1) $ sequence_ $ incrementGain <$> elems (f n `intersection` free)


maxGain :: Gain s a -> ST s (Int, Maybe [a])
maxGain (Gain gmax u m) = do
  g <- Set.findMax <$> readSTRef gmax
  (g, ) <$> H.lookup m g


removeGain :: Int -> Gain s Int -> ST s ()
removeGain c (Gain gmax u m) = do
  mj <- H.lookup u c
  case mj of
    Nothing -> pure ()
    Just j -> do
      mg <- H.lookup m j
      case mg of
        Nothing -> pure ()
        Just [c] -> do
          modifySTRef' gmax $ Set.delete j 
          H.delete m j
        Just [] -> do
          H.delete m j
        Just ds -> do
          H.mutate m j $ (, ()) . pure . maybe [] (filter (/= c))


modifyGain :: (Int -> Int) -> Int -> Gain s Int -> ST s ()
modifyGain f c (Gain gmax u m) = do
  mj <- H.lookup u c
  H.mutate u c $ (, ()) . fmap f
  case mj of
    Nothing -> pure ()
    Just j -> do
      mg <- H.lookup m j
      case mg of
        Nothing -> pure ()
        Just [c] -> do
          modifySTRef' gmax $ Set.delete j 
          H.delete m j
          H.mutate m (f j) $ (, ()) . pure . maybe [c] (c:)
        Just [] -> do
          H.delete m j
          H.mutate m (f j) $ (, ()) . pure . maybe [c] (c:)
        Just ds -> do
          H.mutate m j $ (, ()) . pure . maybe [] (filter (/= c))
          H.mutate m (f j) $ (, ()) . pure . maybe [c] (c:)


incrementGain, decrementGain :: Int -> FM s ()
decrementGain c = lift . modifyGain pred c =<< value gains
incrementGain c = lift . modifyGain succ c =<< value gains


balanceCriterion :: Heu s -> Int -> Int -> Bool
balanceCriterion h smax c
  = div v r - k * smax <= a && a <= div v r + k * smax
  where
    P p q = h ^. partitioning
    a = last $ [succ $ size p] ++ [pred $ size p | member c p]
    v = size p + size q
    k = h ^. freeCells . to size
    r = fromIntegral $ denominator balanceFactor `div` numerator balanceFactor


initialFreeCells :: V -> FM s ()
initialFreeCells v = update freeCells $ const $ fromAscList [0 .. length v - 1]


initialPartitioning :: V -> FM s ()
initialPartitioning v = update partitioning $ const $
  if length v < 30000
  then P (fromAscList [x | x <- base v, parity x]) (fromAscList [x | x <- base v, not $ parity x])
  else P (fromAscList [x | x <- base v, half v x]) (fromAscList [x | x <- base v, not $ half v x])
  where
    base v = [0 .. length v - 1]
    half v i = i <= div (length v) 2
    parity = even


initialGains :: (V, E) -> FM s ()
initialGains (v, e) = do

  gmax <- lift $ newSTRef mempty

  p <- value partitioning

  u <- lift H.new
  lift $ for_ ([0.. ] `zip` toList v) $ \ (i, ns) -> do
    let f = fromBlock p i e
    let t = toBlock p i e
    H.insert u i
      $ size (Set.filter (\ n -> size (f n) == 1) ns)
      - size (Set.filter (\ n -> size (t n) == 0) ns)

  m <- lift H.new
  lift $ do
    es <- HC.toList u
    for_ es $ \ (k, x) -> do
      modifySTRef' gmax $ Set.insert x
      H.mutate m x $ \ v -> case v of
        Nothing -> (Just [k], ())
        Just ks -> (Just (k : ks), ())

  update gains $ const $ Gain gmax u m



fromBlock, toBlock :: Partition -> Int -> E -> Int -> IntSet
fromBlock (P a b) i e n | member i a = intersection a $ e ! n
fromBlock (P a b) i e n = intersection b $ e ! n
toBlock (P a b) i e n | member i a = intersection b $ e ! n
toBlock (P a b) i e n = intersection a $ e ! n


inputRoutine :: Foldable f => Int -> Int -> f (Int, Int) -> FM s (V, E)
inputRoutine n c xs = do
  nv <- replicate n mempty
  cv <- replicate c mempty
  for_ xs $ \ (x, y) -> do
    modify nv (Set.insert y) x
    modify cv (Set.insert x) y
  (,) <$> unsafeFreeze cv <*> unsafeFreeze nv
