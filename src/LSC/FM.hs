{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}

module LSC.FM where

import Control.Lens hiding (indexed)
import Control.Monad
import Control.Monad.Loops
import Control.Monad.Primitive
import Control.Monad.Reader
import Control.Monad.ST
import Data.Foldable
import Data.Function
import Data.Maybe
import Data.Monoid
import Data.HashTable.ST.Cuckoo (HashTable)
import Data.HashTable.ST.Cuckoo (mutate, lookup, new, newSized)
import Data.IntSet hiding (filter, null, foldl', toList)
import qualified Data.IntSet as S
import Data.Ratio
import Data.STRef
import Data.Vector
  ( Vector
  , unsafeFreeze, unsafeThaw
  , freeze, thaw
  , take, generate
  , (!), indexed
  )
import Data.Vector.Mutable (STVector, read, write, modify, replicate, unsafeSwap)
import Prelude hiding (replicate, length, read, lookup, take)
import System.Random.MWC



matchingRatio :: Rational
matchingRatio = 1 % 3

coarseningThreshold :: Int
coarseningThreshold = 35


balanceFactor :: Rational
balanceFactor = 1 % 2


type NetArray  = Vector IntSet
type CellArray = Vector IntSet

type V = CellArray
type E = NetArray


data Gain s a = Gain
  (STRef s IntSet)      -- track existing gains
  (STVector s Int)      -- gains indexed by node
  (HashTable s Int [a]) -- nodes indexed by gain



data Move
  = Move Int Int -- Move Gain Cell
  deriving Show



data Bipartitioning = Bisect !IntSet !IntSet

unBisect :: Bipartitioning -> (IntSet, IntSet)
unBisect (Bisect a b) = (a, b)

instance Eq Bipartitioning where
  Bisect a _ == Bisect b _ = a == b

instance Semigroup Bipartitioning where
  Bisect a b <> Bisect c d = Bisect (a <> c) (b <> d)

instance Monoid Bipartitioning where
  mempty = Bisect mempty mempty
  mappend = (<>)

instance Show Bipartitioning where
  show (Bisect a b) = "<"++ show a ++", "++ show b ++">"

move :: Int -> Bipartitioning -> Bipartitioning
move c (Bisect a b) | member c a = Bisect (delete c a) (insert c b)
move c (Bisect a b) = Bisect (insert c a) (delete c b)

partitionBalance :: Bipartitioning -> Int
partitionBalance (Bisect a b) = abs $ size a - size b


cutSize :: (V, E) -> Bipartitioning -> Int
cutSize (v, _) (Bisect p q) = size $ intersection
    (foldMap (v!) $ elems p)
    (foldMap (v!) $ elems q)


type Clustering = Vector IntSet


type Permutation = Vector Int



data Heu s = Heu
  { _gains        :: Gain s Int
  , _freeCells    :: IntSet
  , _moves        :: [(Move, Bipartitioning)]
  , _iterations   :: !Int
  }

makeFieldsNoPrefix ''Heu


type FM s = ReaderT (GenST s, STRef s (Heu s)) (ST s)


nonDeterministic :: FM RealWorld a -> IO a
nonDeterministic f = withSystemRandom $ \ r -> stToIO $ runFMWithGen r f

prng :: FM s (GenST s)
prng = fst <$> ask


evalFM :: FM s a -> ST s a
evalFM = runFM

runFM :: FM s a -> ST s a
runFM = runFMWithGen $ error "prng not initialized"

runFMWithGen :: GenST s -> FM s a -> ST s a
runFMWithGen s f = do
  g <- Gain <$> newSTRef mempty <*> thaw mempty <*> new
  r <- newSTRef $ Heu g mempty mempty 0
  runReaderT f (s, r)


st :: ST s a -> FM s a
st = lift


update :: Simple Setter (Heu s) a -> (a -> a) -> FM s ()
update v f = do
  r <- modifySTRef . snd <$> ask
  st $ r $ v %~ f

value :: Getter (Heu s) a -> FM s a
value v = view v <$> snapshot

snapshot :: FM s (Heu s)
snapshot = st . readSTRef . snd =<< ask


-- | This function does not reach all possible permutations for lists
--   consisting of more than 969 elements. Any PRNGs possible states
--   are bound by its possible seed values.
--   In the case of MWC8222 the period is 2^8222 which allows for
--   not more than 969! different states.
--
-- seed bits: 8222
-- maximum list length: 969
--
--   969! =~ 2^8222
--
-- Monotonicity of  n! / (2^n): 
--
-- desired seed bits: 256909
-- desired list length: 20000
--
--   20000! =~ 2^256909
--
randomPermutation :: Int -> FM s Permutation
randomPermutation n = do
  v <- st $ unsafeThaw $ generate n id
  for_ [0 .. n - 2] $ \ i -> unsafeSwap v i =<< uniformR (i, n - 1) =<< prng
  unsafeFreeze v



fmMultiLevel :: (V, E) -> Int -> Rational -> FM s Bipartitioning
fmMultiLevel (v, e) t r = do

    i <- st $ newSTRef 0

    hypergraphs  <- replicate 64 mempty
    clustering   <- replicate 64 mempty
    partitioning <- replicate 64 mempty

    write hypergraphs 0 (v, e)

    let continue = pure . (t < ) . length . fst =<< read hypergraphs =<< readSTRef i
    -- let continue = pure False
    whileM_ (st continue) $ do

      hi <- st $ read hypergraphs =<< readSTRef i
      u <- randomPermutation $ length $ fst hi

      st $ do

        modifySTRef' i succ

        -- interim clustering
        pk <- match hi r u

        -- interim hypergraph
        hs <- induce hi pk

        j <- readSTRef i
        write clustering  j pk
        write hypergraphs j hs


    -- number of levels
    m <- st $ readSTRef i

    hi <- read hypergraphs m
    write partitioning m =<< fmPartition hi Nothing

    for_ (reverse [0 .. m - 1]) $ \ j -> do
        p <- project <$> read clustering (succ j) <*> read partitioning (succ j)
        h <- read hypergraphs j
        write partitioning j =<< fmPartition h (Just p)

    read partitioning 0



induce :: (V, E) -> Clustering -> ST s (V, E)
induce (v, e) pk = inputRoutine (length e) (length pk)
    [ (j, k)
    | (k, cluster) <- toList $ indexed pk
    , i <- elems cluster, j <- elems $ v!i
    ]


project :: Clustering -> Bipartitioning -> Bipartitioning
project pk (Bisect p q) = Bisect
    (foldMap (pk!) $ elems p)
    (foldMap (pk!) $ elems q)



match :: (V, E) -> Rational -> Permutation -> ST s Clustering
match (v, e) r p = do

  u <- unsafeThaw $ Just <$> p

  nMatch <- newSTRef 0
  k <- newSTRef 0
  j <- newSTRef 0

  clustering <- replicate (length v) mempty

  connectivity <- thaw $ 0 <$ v

  let continue n i = i < length v && n % fromIntegral (length v) < r
  whileM_ (continue <$> readSTRef nMatch <*> readSTRef j)
    $ do

      unmatched <- read u =<< readSTRef j
      for_ unmatched $ \ uj -> do

          modify clustering (insert uj) =<< readSTRef k

          let neighbours = elems $ foldMap (e!) (elems $ v!uj)

          for_ neighbours $ \ w -> do
              seen <- isNothing <$> read u w
              unless seen $ write connectivity w $ conn w uj

          -- find maximum connectivity
          suchaw <- newSTRef (0, Nothing)
          for_ neighbours $ \ w -> do
              next <- read connectivity w
              (cmax, _) <- readSTRef suchaw
              when (next > cmax) $ writeSTRef suchaw (next, pure w)

          exists <- snd <$> readSTRef suchaw

          for_ exists $ \ w -> do
              modify clustering (insert w) =<< readSTRef k
              modifySTRef' nMatch (+2)
              write u w Nothing

          -- reset connectivity
          for_ neighbours $ flip (write connectivity) 0

          modifySTRef' k succ

      modifySTRef' j succ

  whileM_ ((<) <$> readSTRef j <*> pure (length v))
    $ do

      unmatched <- read u =<< readSTRef j
      for_ unmatched $ \ uj -> do
          modify clustering (insert uj) =<< readSTRef k
          modifySTRef' k succ

      modifySTRef' j succ

  take <$> readSTRef k <*> unsafeFreeze clustering

  where

      conn x y = sum [ 1 % size (e!f) | f <- elems $ intersection (v!x) (v!y), size (e!f) < 10 ]




fmPartition :: (V, E) -> Maybe Bipartitioning -> FM s Bipartitioning
fmPartition (v, e) (Just p) = bipartition (v, e) p
fmPartition (v, e)  Nothing = do
  u <- randomPermutation $ length v
  let (p, q) = splitAt (length v `div` 2) (toList u)
  bipartition (v, e) $ Bisect (fromList p) (fromList q)



fiducciaMattheyses :: (V, E) -> FM s Bipartitioning
fiducciaMattheyses (v, e)
  = bipartition (v, e)
  $ Bisect (fromAscList [x | x <- base, part x]) (fromAscList [x | x <- base, not $ part x])
  where
    base = [0 .. length v - 1]
    part = if length v < 1000
      then even
      else (<= length v `div` 2)


bipartition :: (V, E) -> Bipartitioning -> FM s Bipartitioning
bipartition (v, e) p = do

  update freeCells $ const $ fromAscList [0 .. length v - 1]
  update moves $ const mempty

  initialGains (v, e) p
  processCell (v, e) p

  (g, q) <- computeG p

  update iterations succ

  if g <= 0
    then pure p
    else bipartition (v, e) q



computeG :: Bipartitioning -> FM s (Int, Bipartitioning)
computeG p0 = do
  (_, g, h) <- foldl' accum (0, 0, p0) . reverse <$> value moves
  pure (g, h)
  where
    accum :: (Int, Int, Bipartitioning) -> (Move, Bipartitioning) -> (Int, Int, Bipartitioning)
    accum (gmax, g, _) (Move gc _, q)
      | g + gc > gmax
      = (g + gc, g + gc, q)
    accum (gmax, g, p) (Move gc _, q)
      | g + gc == gmax
      , partitionBalance p > partitionBalance q
      = (gmax, g + gc, q)
    accum (gmax, g, p) (Move gc _, _)
      = (gmax, g + gc, p)



processCell :: (V, E) -> Bipartitioning -> FM s ()
processCell (v, e) p = do
  ck <- selectBaseCell p
  for_ ck $ \ c -> do
    lockCell c
    q <- moveCell c p
    updateGains c (v, e) p
    processCell (v, e) q


lockCell :: Int -> FM s ()
lockCell c = do
  update freeCells $ delete c
  removeGain c


moveCell :: Int -> Bipartitioning -> FM s Bipartitioning
moveCell c p = do
  Gain _ u _ <- value gains
  g <- st $ read u c
  let q = move c p
  update moves ((Move g c, q) :)
  pure q


selectBaseCell :: Bipartitioning -> FM s (Maybe Int)
selectBaseCell p = do
  h <- value freeCells
  bucket <- maxGain
  case bucket of
    Just (i, xs) -> pure $ balanceCriterion h p i `find` xs
    _ -> pure Nothing


updateGains :: Int -> (V, E) -> Bipartitioning -> FM s ()
updateGains c (v, e) p = do

  let f = fromBlock p c e
      t = toBlock p c e

  free <- value freeCells

  for_ (elems $ v ! c) $ \ n -> do

    -- reflect changes before the move
    when (size (t n) == 0) $ for_ (elems $ f n `intersection` free) (modifyGain succ)
    when (size (t n) == 1) $ for_ (elems $ t n `intersection` free) (modifyGain pred)

    -- reflect changes after the move
    when (size (f n) == succ 0) $ for_ (elems $ t n `intersection` free) (modifyGain pred)
    when (size (f n) == succ 1) $ for_ (elems $ f n `intersection` free) (modifyGain succ)



maxGain :: FM s (Maybe (Int, [Int]))
maxGain = do
  Gain gmax _ m <- value gains
  mg <- st $ maxView <$> readSTRef gmax
  case mg of
    Just (g, _) -> do
      mb <- st $ lookup m g
      if maybe True null mb
        then fail $ "maxGain: empty bucket for gain " <> show g
        else pure $ (g, ) <$> mb
    _ -> pure Nothing


removeGain :: Int -> FM s ()
removeGain c = do

  Gain gmax u m <- value gains

  st $ do

    j <- read u c

    mg <- lookup m j
    for_ mg $ \ ds -> do

        when (ds == pure c) $ modifySTRef gmax $ delete j
        mutate m j $ (, ()) . fmap (filter (/= c))



modifyGain :: (Int -> Int) -> Int -> FM s ()
modifyGain f c = do

  Gain gmax u m <- value gains

  st $ do

    j <- read u c
    modify u f c

    mg <- lookup m j
    for_ mg $ \ ds -> do

        when (ds == pure c) $ modifySTRef gmax $ delete j
        mutate m j $ (, ()) . fmap (filter (/= c))

        modifySTRef gmax $ insert (f j)
        mutate m (f j) $ (, ()) . pure . maybe [c] (c:)



initialGains :: (V, E) -> Bipartitioning -> FM s ()
initialGains (v, e) p = do

  let nodes = flip imap v $ \ i ns ->
        let f = fromBlock p i e
            t = toBlock p i e
         in size (S.filter (\ n -> size (f n) == 1) ns)
          - size (S.filter (\ n -> size (t n) == 0) ns)

  let gmax = foldMap singleton nodes

  initial <- st $ do
      gain <- newSized $ size gmax
      flip imapM_ nodes $ \ k x ->
          mutate gain x $ (, ()) . pure . maybe [k] (k:)
      Gain <$> newSTRef gmax <*> thaw nodes <*> pure gain

  update gains $ const initial



balanceCriterion :: IntSet -> Bipartitioning -> Int -> Int -> Bool
balanceCriterion h (Bisect p q) smax c
  = div v r - k * smax <= a && a <= div v r + k * smax
  where
    a = last (succ : [pred | member c p]) (size p)
    v = size p + size q
    k = size h
    r = fromIntegral $ denominator balanceFactor `div` numerator balanceFactor


fromBlock, toBlock :: Bipartitioning -> Int -> E -> Int -> IntSet
fromBlock (Bisect a _) i e n | member i a = intersection a $ e ! n
fromBlock (Bisect _ b) _ e n = intersection b $ e ! n
toBlock (Bisect a b) i e n | member i a = intersection b $ e ! n
toBlock (Bisect a _) _ e n = intersection a $ e ! n


inputRoutine :: Foldable f => Int -> Int -> f (Int, Int) -> ST s (V, E)
inputRoutine n c xs = do
  ns <- replicate n mempty
  cs <- replicate c mempty
  for_ xs $ \ (x, y) -> do
    modify ns (insert y) x
    modify cs (insert x) y
  (,) <$> freeze cs <*> freeze ns

