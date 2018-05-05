{-# LANGUAGE OverloadedStrings #-}

-- | Implementation of "ML pattern match compilation and partial evaluation" by
-- Peter Sestoft

module Amy.Core.MatchCompiler
  ( Con(..)
  , Arity
  , Span
  , Pat(..)
  , Match
  , Decision(..)
  , Access(..)
  , compileMatch
  ) where

import Data.Text (Text)

import Amy.Literal

--
-- Constructor
--

-- | A 'Con' represents a generic pattern constructor.
data Con
  = Con !Text !Span !Arity
    -- ^ A non-literal constructor with a name, span, and arity.
  | ConLit !Literal
    -- ^ A constructor made from a literal. This case is separate because
    -- int/double literals have 0 arity and "infinite" span (represented by
    -- 'Nothing').
  deriving (Show, Eq)

-- | 'Arity' is the number of arguments a constructor takes. A constructor with
-- no arguments has arity 0, and a constructor with N arguments has arity N.
type Arity = Int

-- | The 'Span' of a constructor is the total number of constructors in the
-- constructor's type. For example, in @data Bool = False | True@, each
-- constructor @False@ and @True@ have span 2 since there are two constructors.
type Span = Int

-- | Returns a 'Con's arity or 0 for a 'ConLit'
conArity :: Con -> Arity
conArity (Con _ arity _) = arity
conArity (ConLit _) = 0

-- | The span of a 'Con'. Returns 'Just' for a constructor with finite span and
-- 'Nothing' for a constructor with infinite span.
conSpan :: Con -> Maybe Span
conSpan (Con _ _ span') = Just span'
conSpan (ConLit _) = Nothing

--
-- Patterns and Matches
--

-- | A 'Pat'tern is either a variable or a constructor applied to more
-- patterns.
data Pat
  = PVar !Text
  | PCon !Con ![Pat]
  deriving (Show, Eq)

type MatchRule a = (Pat, a)
type Match a = [MatchRule a]

--
-- Term Description
--

-- | A 'TermDesc'ription describes information we know about a given term.
data TermDesc
  = Pos Con [TermDesc]
    -- | A 'Pos'itive description describes a term we know has a constructor
    -- 'Con', and with a 'TermDescr' for each argument.
  | Neg [Con]
    -- | A 'Neg'ative description describes a term who's constructor is none of
    -- the given constructors.
  deriving (Show, Eq)

--
-- Main Algorithm
--

-- | A 'Decision' is a tree-like structure describing how to match an object.
data Decision a
  = Failure
    -- ^ Leaf node when matching has failed
  | Success a
    -- ^ Leaf node when matching has succeeded
  | Switch Access [(Con, Decision a)] (Decision a)
  deriving (Show, Eq)

-- | A 'PrelimDecision' is like 'Decision' except it is made of simple 'IfEq'
-- branches. It gets compiled to a 'Decision' by turning consecutive
data PrelimDecision a
  = Failure'
    -- ^ Leaf node when matching has failed
  | Success' a
    -- ^ Leaf node when matching has succeeded
  | IfEq Access Con (PrelimDecision a) (PrelimDecision a)
    -- ^ Tests if the given subterm 'Access' of the object is equal to 'Con'.
    -- If it does, then follow the first 'PrelimDecision', and otherwise follow
    -- the second.
  deriving (Show, Eq)

-- | Main pattern compilation algorithm. This algorithm takes a list of match
-- rules and produces a tree-like 'Decision' structure describing statically
-- how to match a term object against the match rules.
--
-- The mutually recursive functions 'compileFail', 'compileSucceed', and
-- 'match' are the meat of the algorithm.
compileMatch :: Match a -> Decision a
compileMatch = switchify . compileMatch'

compileMatch' :: Match a -> PrelimDecision a
compileMatch' = compileFail (Neg [])

-- TODO: Document this
compileFail :: TermDesc -> Match a -> PrelimDecision a
compileFail _ [] = Failure'
compileFail dsc ((pat1, rhs1):rulesrest) = match pat1 Obj dsc [] [] rhs1 rulesrest

-- TODO: Document this
compileSucceed :: [(Con, [TermDesc])] -> [([Pat], [Access], [TermDesc])] -> a -> Match a -> PrelimDecision a
compileSucceed _ [] rhs _ = Success' rhs
compileSucceed ctx (work1:workr) rhs rules =
  case work1 of
    ([], [], []) -> compileSucceed (norm ctx) workr rhs rules
    (pat1:patr, obj1:objr, dsc1:dscr) ->
      match pat1 obj1 dsc1 ctx ((patr, objr, dscr):workr) rhs rules
    (x, y, z) -> error $ "succeed found work args of different length " ++ show (x, y, z)

-- TODO: Document this
match :: Pat -> Access -> TermDesc -> [(Con, [TermDesc])] -> [([Pat], [Access], [TermDesc])] -> a -> Match a -> PrelimDecision a
match (PVar _) _ dsc ctx work rhs rules = compileSucceed (augment ctx dsc) work rhs rules
match (PCon pcon pargs) obj dsc ctx work rhs rules =
  let
    args f = tabulate (conArity pcon) f

    getdargs (Neg _) = args (const $ Neg [])
    getdargs (Pos _ dargs) = dargs

    getoargs = args (\i -> Sel (i+1) obj)

    succeed' = compileSucceed ((pcon, []):ctx) ((pargs, getoargs, getdargs dsc):work) rhs rules

    compileFail' newdsc = compileFail (builddsc ctx newdsc work) rules
  in
    case staticmatch pcon dsc of
      Yes -> succeed'
      No -> compileFail' dsc
      Maybe' negcons -> IfEq obj pcon succeed' $ compileFail' $ Neg negcons

augment :: [(Con, [TermDesc])] -> TermDesc -> [(Con, [TermDesc])]
augment [] _ = []
augment ((con, args):rest) dsc = (con, dsc:args):rest

norm :: [(Con, [TermDesc])] -> [(Con, [TermDesc])]
norm [] = error "Unexpected empty list in norm"
norm ((con, args):rest) = augment rest (Pos con (reverse args))

builddsc :: [(Con, [TermDesc])] -> TermDesc -> [([Pat], [Access], [TermDesc])] -> TermDesc
builddsc [] dsc [] = dsc
builddsc ((con, args):rest) dsc ((_, _, dargs):work) =
  builddsc rest (Pos con (reverse args ++ (dsc : dargs))) work
builddsc a b c = error $ "Encountered problem in builddsc " ++ show (a, b, c)

-- | An 'Access' path is either the full object or a path to select sub-terms
-- of the object.
data Access
  = Obj
    -- ^ Full object
  | Sel !Int !Access
    -- ^ Select the i-th subterm of the given 'Access' path.
  deriving (Show, Eq)

tabulate :: Int -> (Int -> a) -> [a]
tabulate i f = f <$> [0..(i-1)]

data StaticMatchResult
  = Yes
  | No
  | Maybe' [Con]
    -- ^ The '[Con]' is the new list of negative constructors.
  deriving (Show, Eq)

-- | Attempt to match a constructor against the term description of a pattern.
staticmatch :: Con -> TermDesc -> StaticMatchResult
staticmatch pcon (Pos con _) =
  if con == pcon
    -- We positively know the object constructor is @con@ and @pcon@ matches
    then Yes
    -- We positively know the object constructor is @con@ and @pcon@ doesn't
    -- match
    else No
staticmatch pcon (Neg negcons)
  -- We know that the object constructor is not one of @negcons@, but the given
  -- constructor is one of those constructors.
  | pcon `elem` negcons = No
  -- We know that the given constructor is not one of @negcons@ and there are
  -- no possibilities left because of the span. Note this never applies to
  -- constructors with infinite span like number literals.
  | pcon `notElem` negcons && conSpan pcon == Just (length negcons + 1) = Yes
  -- We know
  | otherwise = Maybe' (pcon:negcons)

-- | Convert a 'PrelimDecision' into a 'Decision' by converting all consecutive
-- 'IfEq' nodes into 'Switch' nodes.
switchify :: PrelimDecision a -> Decision a
switchify Failure' = Failure
switchify (Success' x) = Success x
switchify (IfEq acc con successDec failDec) =
  let
    (cases, defaultCase) = collectSwitch acc failDec [(con, switchify successDec)]
  in Switch acc cases defaultCase

-- | Collect consecutive 'IfEq' nodes into a list of 'Switch' decisions as long
-- as they are acting on the same 'Access' path.
collectSwitch :: Access -> PrelimDecision a -> [(Con, Decision a)] -> ([(Con, Decision a)], Decision a)
collectSwitch acc failDec otherDecs =
  case failDec of
    IfEq acc' con' successDec' failDec' ->
      if acc == acc'
        then collectSwitch acc failDec' (otherDecs ++ [(con', switchify successDec')])
        else (otherDecs, switchify failDec)
    _ -> (otherDecs, switchify failDec)
