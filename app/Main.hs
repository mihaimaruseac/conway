{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Main where

import Control.Concurrent (threadDelay, forkIO)
import Control.Concurrent.STM
import Control.Monad (void, forever)
import Control.Monad.IO.Class (liftIO)
import Data.Monoid ((<>))
import Data.Maybe (fromMaybe)
import Lens.Micro ((^.), (^?), (&), (%~), (.~), (<&>), set, to, ix)
import Lens.Micro.TH

import Life hiding (board)
import qualified Life as L
import qualified Life.Examples as LE
import Math.Geometry.Grid (size)
import Math.Geometry.GridMap (toList)
import qualified Math.Geometry.GridMap as GM

import Brick
import Brick.BChan
import Brick.Widgets.Core
  ( (<+>), (<=>)
  , hBox
  , withBorderStyle
  , emptyWidget
  , padLeftRight
  , padTopBottom
  )
import qualified Brick.Widgets.Center as C
import qualified Brick.Widgets.Border as B
import qualified Brick.Widgets.ProgressBar as P
import qualified Brick.Widgets.Border.Style as BS
import qualified Graphics.Vty as V

-- Game State

-- | Game state
data Game = Game { _board    :: Board -- ^ Board state
                 , _time     :: Int   -- ^ Time elapsed
                 , _paused   :: Bool  -- ^ Playing vs. paused
                 , _speed    :: Float -- ^ Speed in [0..1]
                 , _interval :: TVar Int -- ^ Interval kept in TVar
                 }

makeLenses ''Game

-- | Initial game with empty board
initialGame :: TVar Int -> Game
initialGame tv = Game { _board    = L.board minG minG []
                      , _time     = 0
                      , _paused   = True
                      , _speed    = initialSpeed
                      , _interval = tv
                      }

initialSpeed :: Float
initialSpeed = 0.75

-- | Speed increments = 0.01 gives 100 discrete speed settings
speedInc :: Float
speedInc = 0.01

-- | Minimum interval (microseconds)
--
-- Corresponding speed == 4 frames / second
minI :: Int
minI = 100000

-- | Maximum interval (microseconds)
--
-- Corresponding speed == 0.5 frames / second
maxI :: Int
maxI = 2000000

-- | Mid interval (microseconds)
midI :: Int
midI = (maxI - minI) `div` 2 + minI

-- Interface

-- | Tick is exactly what it sounds like - the tick of the counter event stream
-- It in and of itself does not "count" anything and thus is not a counter
data Tick = Tick

-- | Name resources (needed for scrollable viewport)
data Name = ExampleVP
  deriving (Ord, Show, Eq)

app :: App Game Tick Name
app = App { appDraw = drawUI
          , appChooseCursor = neverShowCursor -- TODO keep track of "focus" in state
                                              -- and implement cursor chooser based on that
                                              -- although.. prob dont need cursor?
          , appHandleEvent = handleEvent
          , appStartEvent = return -- TODO setup grid size here!
          , appAttrMap = const $ gameAttrMap
          }

---- Drawing

drawUI :: Game -> [Widget Name]
drawUI g = [ vBox [ drawGrid (g^.board)
                  , hBox $ padTopBottom 1 . vLimit 6
                    <$> [ drawSpeedBar (g^.speed)
                        , drawPButton (g^.paused)
                        , drawExamples
                        ]
                   ]
           ]

-- | Draw grid
--
-- BIG asterisk *** I wanted this to be reasonably performant,
-- so I'm leveraging the fact that 'toList' returns ordered tiles.
--
drawGrid :: Board -> Widget n
drawGrid b =
  withBorderStyle BS.unicodeBold $
  B.borderWithLabel (str "Game of Life") $
  C.center $
  fst $ toCols (emptyWidget, toList $ b)
    where toCols :: (Widget n, [(Cell, St)]) -> (Widget n, [(Cell, St)])
          toCols (w,[]) = (w,[])
          toCols (w,xs) = let (c,cs) = splitAt rowT xs
                           in toCols (w <+> mkCol c, cs)
          mkCol :: [(Cell, St)] -> Widget n
          mkCol = foldr (flip (<=>) . renderSt . snd) emptyWidget
          rowT :: Int
          rowT  = fst . size $ b

drawSpeedBar :: Float -> Widget n
drawSpeedBar s =
  padTopBottom 2 $
  P.progressBar (Just lbl) s
    where lbl = "Speed: "
              <> show (fromEnum $ s * 100)
              <> "  "
              <> "(Ctrl <-,->)"

drawPButton :: Bool -> Widget n
drawPButton pause = padTopBottom 1 $ mkButton $
  if pause
     then withAttr pausedAttr $ str "Play (Space)"
     else withAttr playingAttr $ str "Pause (Space)"

drawExamples :: Widget Name
drawExamples =
  mkBox BS.unicodeRounded "Examples (Press number)" $
  vLimit 4 $ hLimit 24 $
  viewport ExampleVP Vertical $
  padRight Max $
  str $ unlines $ zipWith lbl [0..] examples
    where lbl n (s, _) = show n ++ ". " ++ s

examples :: [(String, (Int -> Int -> Board))]
examples =
  [ ("Glider", LE.glider)
  , ("Pentadecathlon", LE.pentadecathlon)
  , ("Beacon", LE.beacon)
  , ("Toad", LE.toad)
  , ("Blinker", LE.blinker)
  , ("Tub", LE.tub)
  , ("Beehive", LE.beehive)
  , ("Block", LE.block)
  ]

mkButton :: Widget n -> Widget n
mkButton = B.border . withBorderStyle BS.unicodeRounded . padLeftRight 1

mkBox :: BS.BorderStyle -> String -> Widget n -> Widget n
mkBox bs s = withBorderStyle bs . B.borderWithLabel (str s)

renderSt :: St -> Widget n
renderSt Alive = withAttr aliveAttr cw
renderSt Dead = withAttr deadAttr cw

aliveAttr, deadAttr :: AttrName
aliveAttr = "alive"
deadAttr = "dead"

pausedAttr, playingAttr :: AttrName
pausedAttr = "paused"
playingAttr = "playing"

gameAttrMap :: AttrMap
gameAttrMap = attrMap V.defAttr
              [ (aliveAttr,                bg V.white)
              , (deadAttr,                 bg V.black)
              , (pausedAttr,               V.blue `on` V.green)
              , (playingAttr,              V.blue `on` V.red)
              , (P.progressIncompleteAttr, V.blue `on` V.yellow)
              , (P.progressCompleteAttr,   V.blue `on` V.green)
              ]

-- | Cell widget
cw :: Widget n
cw = str "  "

-- | Min grid side
minG :: Int
minG = 30

---- Events

-- TODO look in mouse demo for handling mouse events in different layers!
handleEvent :: Game -> BrickEvent Name Tick -> EventM Name (Next Game)
handleEvent g (AppEvent Tick) = continue $
  if (g^.paused || g^.speed == 0)
     then g
     else forward g
handleEvent g (VtyEvent (V.EvKey V.KRight [V.MCtrl])) = handleSpeed g (+)
handleEvent g (VtyEvent (V.EvKey V.KLeft [V.MCtrl]))  = handleSpeed g (-)
handleEvent g (VtyEvent (V.EvKey V.KUp [V.MCtrl]))    = scrollEx (-1) >> continue g
handleEvent g (VtyEvent (V.EvKey V.KDown [V.MCtrl]))  = scrollEx 1 >> continue g
handleEvent g (VtyEvent (V.EvKey (V.KChar 'n') []))   = continue $ forward g
handleEvent g (VtyEvent (V.EvKey (V.KChar ' ') []))   = continue $ g & paused %~ not
handleEvent g (VtyEvent (V.EvKey (V.KChar 'c') []))   = continue $ g & board %~ GM.map (const Dead)
handleEvent g (VtyEvent (V.EvKey (V.KChar n) []))
  | n `elem` ['0'..'9']                               = handleExample g n
  | otherwise                                         = continue g
handleEvent g _                                       = halt g

forward :: Game -> Game
forward = (& board %~ step) . (& time %~ succ)

handleSpeed :: Game -> (Float -> Float -> Float) -> EventM n (Next Game)
handleSpeed g (+/-) = do
  let newSp = validS $ (g^.speed) +/- speedInc
  liftIO $ atomically $ writeTVar (g^.interval) (spToInt newSp)
  continue $ g & speed .~ newSp

handleExample :: Game -> Char -> EventM n (Next Game)
handleExample g n = continue $ fromMaybe g mg
  where mg    = set paused True <$> (set board <$> (me <*> Just h <*> Just l) <*> Just g)
        me    = examples ^? ix (read [n]) <&> snd
        (h,l) = g ^. board . to size


scrollEx :: Int -> EventM Name ()
scrollEx n = (viewportScroll ExampleVP) `vScrollBy` n

validS :: Float -> Float
validS = clamp 0 1

-- | Get interval from progress bar float (between 1 and
spToInt :: Float -> Int
spToInt = floor . toInterval . validS
  where toInterval x = (fromIntegral $ maxI - minI) * (1 - x)
                        + fromIntegral minI

-- Runtime

main :: IO ()
main = do
  chan <- newBChan 10
  tv   <- atomically $ newTVar (spToInt initialSpeed)
  forkIO $ forever $ do
    writeBChan chan Tick
    int <- atomically $ readTVar tv
    threadDelay int
  customMain (V.mkVty V.defaultConfig) (Just chan) app (initialGame tv) >>= printResult

printResult :: Game -> IO ()
printResult g = mapM_ putStrLn
  [ "Your game ended with"
  , "  population: " <> p
  , "        time: " <> t
  ]
    where p = show $ population $ g^.board
          t = show $ g^.time


-- Layer with "how to" info (see layer demo on not interfering with grid)
-- Little floating box with current time & population
-- Grid with squares that can be traversed via arrow keys
-- Spacebar to toggle Alive / Dead
-- Mouse click on
  -- cell -> toggle Alive/Dead
  -- take a look at MouseDemo.hs -- probably need layer for each box?
-- Clear button (c)
-- Change grid size on terminal resize (& start grid size based on this)
  -- Ah. We need custom widgets for contextual info: https://github.com/jtdaugherty/brick/blob/master/docs/guide.rst#implementing-custom-widgets
-- Small text at the bottom with current grid size, e.g. 200 x 220

-- Possible features
  -- Typeclass for cellular automata ca g st (only 2d ?, maybe 2d subclass ?)
    -- methods: size :: (Int, Int)
    --          step :: (ca -> ca)
    --          rule :: (g -> st -> st) ? hmm need to think more about this
  -- Allow two list boxes that specify exactly how many live neighbors results in Live cell,
     -- for alive/dead cells respectively
     -- cool for people exploring rules of cellular automata

-- Questions/Thoughts
  -- Profile via criterion before asking r/haskell for performance advice
  -- Why doesn't below work? Keyboard/terminal specifics?
    --handleEvent g (VtyEvent (V.EvKey (V.KChar ' ') [V.MShift])) = continue $ forward g
