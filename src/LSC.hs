{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
{-# LANGUAGE GADTs, DataKinds, TupleSections, FlexibleContexts #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE ScopedTypeVariables #-}

module LSC where

import Data.Monoid
import Data.Text (unpack)
import Data.Foldable
import qualified Data.Map as Map

import Data.SBV
import Data.SBV.Control

import LSC.NetGraph
import LSC.Types
import LSC.Exlining


type Stage1 = Circuit2D

stage1 :: Int -> NetGraph -> LSC Stage1
stage1 j
  = fmap head
  . concLSC
  . take j
  . fmap pnr
  . getLeaves
  . exline (repeat 20)


pnr :: NetGraph -> LSC Circuit2D
pnr (NetGraph ident (inputList, _, _) _ gates wires) = do

  nodes <- Map.fromList <$> sequence (freeNode <$> toList gates)
  edges <- Map.fromList <$> sequence (freeEdge <$> toList wires)

  steiner <- Map.fromList <$> sequence (freeSteiner <$> inputList)

  collision nodes
  boundedSpace nodes

  connect steiner nodes edges

  rectangular edges
  shorten edges

  -- intersections edges

  liftSMT $ query $ do
    result <- checkSat
    case result of

      Sat -> Circuit2D

        <$> sequence
            [ fmap (gate, ) $ (,,,) <$> getValue x <*> getValue y <*> getValue w <*> getValue h
            | (gate, (x, y, w, h)) <- Map.assocs nodes
            ]

        <*> sequence
            [ fmap (net, ) $ Path <$> sequence
                [ (, ) <$> getValue x <*> getValue y | (x, y) <- path ]
            | (net, path) <- Map.assocs edges
            ]

      _   -> pure $ Circuit2D [] []


boundedSpace nodes = do
  (width, height) <- padDimensions <$> ask
  sequence_
    [ liftSMT $ constrain
        $   x .> literal 0
        &&& y .> literal 0
        &&& x .< literal width
        &&& y .< literal height
    | (x, y, _, _) <- Map.elems nodes
    ]


collision nodes = do
  sequence_
    [ liftSMT $ constrain
        $   x1 .> x2 &&& x1 - x2 .> w2
        ||| x2 .> x1 &&& x2 - x1 .> w1
        ||| y1 .> y2 &&& y1 - y2 .> h2
        ||| y2 .> y1 &&& y2 - y1 .> h1
    | (i, (x1, y1, w1, h1)) <- zip [ 1 .. ] $ Map.elems nodes
    ,     (x2, y2, w2, h2)  <- drop i $ Map.elems nodes
    ]


connect steiner nodes edges = do
  sequence_
    [ do
      liftSMT $ constrain
        $   sourceCoords `sElem` path
        &&& targetCoords `sElem` path

    | (wire, path) <- Map.assocs edges
    , (x1, y1) <- maybe [] pure $ Map.lookup (netIdent wire) steiner
    , (target, cs) <- Map.assocs $ contacts wire
    , (_, pin) <- take 1 cs
    , (tx, ty, _, _) <- take 1 $ portRects $ pinPort pin
    , (x2, y2, _, _) <- maybe [] pure $ Map.lookup target nodes
    , let sourceCoords = (x1, y1)
    , let targetCoords = (x2 + literal tx, y2 + literal ty)
    ]


rectangular edges = sequence_ [ liftSMT $ rect path | path <- Map.elems edges ]

rect ((x1, y1) : (x2, y2) : xs) = do
  constrain $ x1 .== x2 ||| y1 .== y2
  rect $ (x2, y2) : xs
rect _ = pure ()


shorten edges = sequence_ [ liftSMT $ short net path | (net, path) <- Map.assocs edges ]

short net path = do

  let goal = "min_p_" ++ show (netIndex net)

  minimize goal $ sum
    [ abs (x1 - x2) + abs (y1 - y2)
    | (x1, y1) <- path
    | (x2, y2) <- drop 1 path
    ]


freeSteiner :: Identifier -> LSC (Identifier, (SInteger, SInteger))
freeSteiner wire = do

  liftSMT $ do
    x <- free_
    y <- free_

    pure (wire, (x, y))


freeNode :: Gate -> LSC (Gate, (SInteger, SInteger, SInteger, SInteger))
freeNode gate = do

  (width, height) <- lookupDimensions gate <$> ask

  liftSMT $ do
    x <- free_
    y <- free_
    w <- free_
    h <- free_

    constrain $ w .== literal width
    constrain $ h .== literal height

    pure (gate, (x, y, w, h))


freeEdge :: Net -> LSC (Net, [(SInteger, SInteger)])
freeEdge net = do

  resolution <- wireResolution <$> ask

  path <- sequence $ replicate resolution $ liftSMT $ (,) <$> free_ <*> free_

  pure (net, path)

