{-# LANGUAGE OverloadedStrings #-}

module Amy.Core.MatchCompilerSpec
  ( spec
  ) where

import Test.Hspec

import Amy.Core.MatchCompiler
import Amy.Literal

trueC, falseC :: Con
trueC = Con "True" 0 2
falseC = Con "False" 0 2

trueP :: Pat
trueP = PCon trueC []

falseP :: Pat
falseP = PCon falseC []

tupP :: [Pat] -> Pat
tupP args = PCon (Con "" (length args) 1) args

litP :: Literal -> Pat
litP lit = PCon (ConLit lit) []

-- data Color = Red | Blue | Green

-- redC, blueC, greenC :: Con
-- redC = Con "Red" 0 3
-- blueC = Con "Blue" 0 3
-- greenC = Con "Green" 0 3

-- redP, blueP, greenP :: Pat
-- redP = PCon redC []
-- blueP = PCon blueC []
-- greenP = PCon greenC []

varC, lamC, appC, letC :: Con
varC = Con "Var" 1 4
lamC = Con "Lam" 2 4
appC = Con "App" 2 4
letC = Con "Let" 3 4

lamMatch :: Match Int
lamMatch =
  [ (PCon varC [PVar "x"], 111)
  , (PCon lamC [PVar "x", PCon varC [PVar "y"]], 222)
  , (PCon lamC [PVar "x", PCon lamC [PVar "y", PVar "z"]], 333)
  , (PCon lamC [PVar "x", PCon appC [PVar "y", PVar "z"]], 444)
  , (PCon appC [PCon lamC [PVar "x", PVar "y"], PVar "z"], 555)
  --, (PCon appC [PCon appC [PCon lamC [PVar "x", PCon lamC [PVar "y", PVar "z"]], PVar "v"], PVar "w"], 0)
  , (PCon appC [PCon appC [PVar "x", PVar "y"], PVar "z"], 666)
  , (PCon letC [PVar "x", PCon letC [PVar "y", PVar "z", PVar "v"], PVar "w"], 777)
  , (PCon lamC [PVar "x", PCon letC [PVar "y", PVar "z", PVar "v"]], 888)
  , (PCon letC [PVar "x", PVar "y", PCon appC [PVar "z", PVar "v"]], 999)
  , (PCon appC [PCon appC [PCon lamC [PVar "x", PCon lamC [PVar "y", PVar "z"]], PVar "v"], PVar "w"], 1010)
  ]

expectedLamCompile :: Decision Int
expectedLamCompile =
  Switch Obj
  [ (varC, Success 111)
  , ( lamC
    , Switch (Sel 1 Obj)
      [ (varC, Success 222)
      , (lamC, Success 333)
      , (appC, Success 444)
      ]
      (Success 888)
    )
  , ( appC
    , Switch (Sel 0 Obj)
      [ (lamC, Success 555)
      , (appC, Success 666)
      ]
      Failure
    )
  ]
  (Switch (Sel 1 Obj)
     [ (letC, Success 777)
     ]
     (Switch (Sel 2 Obj)
        [ (appC, Success 999)
        ]
        Failure
     )
  )

spec :: Spec
spec = do

  describe "compileMatch" $ do

    it "handles a simple true/false case" $ do
      let
        match =
          [ (trueP, 'a')
          , (falseP, 'b')
          ]
        expected =
          Switch Obj
          [(trueC, Success 'a')]
          (Success 'b')
      compileMatch match `shouldBe` expected

    it "handles a tuple true/false case" $ do
      let
        match =
          [ (tupP [trueP, trueP], '1')
          , (tupP [falseP, falseP], '2')
          , (tupP [trueP, falseP] , '3')
          , (tupP [falseP, trueP], '4')
          ]
        expected =
          Switch (Sel 0 Obj)
          [ ( trueC
            , Switch (Sel 1 Obj)
              [ (trueC, Success '1')
              ]
              (Success '3')
            )
          ]
          ( Switch (Sel 1 Obj)
            [ (falseC, Success '2')
            ]
            (Success '4')
          )
      compileMatch match `shouldBe` expected

    it "handles literals" $ do
      let
        match =
          [ (litP (LiteralInt 1), 'a')
          , (litP (LiteralInt 2), 'b')
          , (PVar "x", 'c')
          , (litP (LiteralInt 4), 'd') -- Redundant
          ]
        expected =
          Switch Obj
          [ (ConLit (LiteralInt 1), Success 'a')
          , (ConLit (LiteralInt 2), Success 'b')
          ]
          (Success 'c')
      compileMatch match `shouldBe` expected

    it "handles the example from the Sestoft paper" $ do
      compileMatch lamMatch `shouldBe` expectedLamCompile
