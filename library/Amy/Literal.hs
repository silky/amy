-- | Common AST components shared across various actual ASTs.

module Amy.Literal
  ( Literal(..)
  , showLiteral
  , literalType
  ) where

import Amy.Prim

-- | A 'Literal' is any literal from the source code. This type is used in many
-- ASTs since there is no need for renaming or annotating types to a literal.
data Literal
  = LiteralInt !Int
  | LiteralDouble !Double
  deriving (Show, Eq)

showLiteral :: Literal -> String
showLiteral (LiteralInt x) = show x
showLiteral (LiteralDouble x) = show x

literalType :: Literal -> PrimTyCon
literalType (LiteralInt _) = intTyCon
literalType (LiteralDouble _) = doubleTyCon
