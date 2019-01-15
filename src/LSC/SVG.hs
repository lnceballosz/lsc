{-# LANGUAGE OverloadedStrings #-}

module LSC.SVG where

import Control.Lens
import Data.Foldable
import Data.String
import Data.Map (assocs)
import Data.Text hiding (take)
import Data.Vector (indexM)
import qualified Data.Text as Text
import qualified Data.Text.Lazy    as Lazy
import qualified Data.Text.Lazy.IO as Lazy

import Text.Blaze.Svg11 ((!), mkPath, m, l, z)
import qualified Text.Blaze.Svg11 as S
import qualified Text.Blaze.Svg11.Attributes as A
import Text.Blaze.Svg.Renderer.Text (renderSvg)

import LSC.Types


type Circuit = Circuit2D Path

type Svg = S.Svg

type Options = (S.AttributeValue, S.AttributeValue)


plotStdout :: NetGraph -> IO ()
plotStdout = Lazy.putStr . plot


plot :: NetGraph -> Lazy.Text
plot = renderSvg . svgDoc . scaleDown 100 . svgPaths


svgDoc :: Circuit -> Svg
svgDoc (Circuit2D nodes edges) = S.docTypeSvg
  ! A.version "1.1"
  ! A.width "100000"
  ! A.height "100000"
  $ do
    place `mapM_` nodes
    route `mapM_` edges


place :: (Gate, Path) -> Svg
place (g, path@(Rect (x, y) _ : _)) = do

  S.text_
    ! A.x (S.toValue $ x + 42)
    ! A.y (S.toValue $ y + 24)
    ! A.fontSize "24"
    ! A.fontFamily "monospace"
    ! A.transform (fromString $ "rotate(90 "++ show (x + 8) ++","++ show (y + 24)  ++")")
    $ renderText $ g ^. identifier

  follow ("black", "transparent") path

place _ = pure ()


route :: Arboresence Path -> Svg
route (net, _, path) | net ^. identifier == "vdd" = do
  follow ("green", "green") path
route (_, pin, path) = do
  follow ("blue", "blue") path
  follow ("black", "blue") pin


follow :: Options -> Path -> Svg
follow (stroke, fill) (x : xs) = do

  S.path
    ! A.d (mkPath pen)
    ! A.stroke stroke
    ! A.fill fill
    ! A.strokeWidth "4"

  follow (stroke, fill) xs

  where

    pen = do
      left x `m` bottom x
      left x `l` top x
      right x `l` top x
      right x `l` bottom x
      z


follow _ _ = pure ()


svgPaths :: NetGraph -> Circuit
svgPaths netlist = Circuit2D

  [ (gate, gate ^. geometry)
  | gate <- toList $ netlist ^. gates
  ]

  [ (net, outerPins net ++ (inducePins =<< assocs (net ^. contacts)), net ^. geometry)
  | net <- (vdd & geometry .~ (netlist ^. supercell . powerRing)) : toList (netlist ^. nets)
  ]

  where

    outerPins :: Net -> Path
    outerPins net =
      [ rect
      | pin <- toList $ netlist ^. supercell . pins
      , view identifier pin == view identifier net
      , rect <- pin ^. port . geometry
      ]

    inducePins :: (Gate, [Pin]) -> Path
    inducePins (i, ps) =
      [ Rect (left r + x, bottom r + y) (right r + x, top r + y)
      | pin <- ps
      , Rect (x, y) _ <- take 1 . view geometry =<< indexM (netlist ^. gates) (i ^. integer)
      , r <- take 1 $ pin ^. port . geometry
      ]


scaleDown :: Integer -> Circuit -> Circuit
scaleDown n (Circuit2D nodes edges) = Circuit2D

  [ (gate, f (`div` n) path)
  | (gate, path) <- nodes
  , let f = fmap . fmap
  ]

  [ (net, f (`div` n) ps, f (`div` n) path)
  | (net, ps, path) <- edges
  , let f = fmap . fmap
  ]


renderText :: Text -> Svg
renderText = fromString . Text.unpack

