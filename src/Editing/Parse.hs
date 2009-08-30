{-# LANGUAGE OverlappingInstances, UndecidableInstances, Arrows, FlexibleInstances, TypeSynonymInstances #-}
{-# OPTIONS -cpp #-}

module Editing.Parse (commandsP, finalCommandP) where

import qualified Cxx.Parse
import qualified Cxx.Basics
import qualified Cxx.Operations
import qualified Parsers as P
import qualified Data.List as List
import qualified Data.NonEmptyList as NeList
import Data.NonEmptyList (NeList(..))
import Control.Monad.Error ()
import Control.Category (Category, (.), id)
import Control.Arrow (Arrow, (>>>), first, second, arr, ArrowChoice(..), returnA)
import Data.Either (partitionEithers)
import Data.Generics (DataType, Constr, toConstr, Data)
import Parsers (choice, eof, (<|>), (<?>), symbols, char, anySymbol, lookAhead, notFollowedBy, many1Till, optParser, try, many, satisfy, spaces)
import Util (isVowel, (<<), snd_unit, liftA2, Ordinal(..), apply_if, cardinals, plural)
import Cxx.Basics (DeclaratorId)
import Request (EvalOpt)

import Prelude hiding ((.), id, and)
import Editing.Basics

data Terminators = Terminators { term_eof :: Bool, term_keywords :: [String], and_conts :: [String] } deriving Eq
  -- term_eof states whether eof is a valid termination of a directly preceding verbatim stings.
  -- term_keywords lists keywords that should terminate directly preceding verbatim strings.
  -- and_conts lists keywords that should terminate directly preceding "and"-lists (when appearing after "and ").

data Parser a b = Parser Terminators (Terminators -> a -> P.Parser Char (Either String b))

terminators :: Parser a b -> Terminators
terminators (Parser t _) = t

commit :: Parser a b -> Parser a b
commit (Parser t f) = Parser t $ \t' v -> P.commit (f t' v)

instance Category Parser where
  id = Parser (Terminators True [] []) $ const $ return . return
  p' . Parser (Terminators b t na) f =
    Parser (Terminators (b && term_eof (terminators p')) (if null t then term_keywords $ terminators p' else t)
        (if null t then and_conts $ terminators p' else na))
     $ \(Terminators b'' t'' a) x -> do
      let (Parser (Terminators b' t' na') f') = p'
        -- Todo: This match is delayed for a reason, I think. Document that reason.
      u <- f (Terminators (b' && b'') (if b' then t' ++ t'' else t') (if b' then a++na' else na')) x
      case u of
        Left e -> return $ Left e
        Right u' -> f' (Terminators b'' t'' a) u'

instance Arrow Parser where
  arr f = Parser (Terminators True [] []) $ \_ -> return . return . f
  first (Parser ac f) = Parser ac $ \y (b, d) -> fmap (fmap (\c' -> (c', d))) (f y b)
  second (Parser ac f) = Parser ac $ \y (d, b) -> fmap (fmap (\c' -> (d, c'))) (f y b)

instance ArrowChoice Parser where
  left (Parser t p) = Parser t $ \t' x ->
    case x of
      Left y -> fmap Left `fmap` p t' y
      Right y -> return $ Right $ Right y
  right (Parser t p) = Parser t $ \t' x ->
    case x of
      Left y -> return $ Right $ Left y
      Right y -> fmap Right `fmap` p t' y

class Parse a where parse :: Parser x a

kwd :: [String] -> Parser a String
kwd s = Parser (Terminators False s []) $ \(Terminators b _ _) _ -> fmap Right $ try $
  choice (try `fmap` symbols `fmap` s) << apply_if b (eof <|>) (P.char_unit ' ')

label :: String -> Parser a b -> Parser a b
label s (Parser t f) = Parser t $ \l x -> f l x <?> s

(<||>) :: Parser a b -> Parser a b -> Parser a b
Parser (Terminators b t a) f <||> Parser (Terminators b' t' a') f' =
  Parser (Terminators (b || b') (t ++ t') (a ++ a')) $ \y x -> f y x <|> f' y x

named_characters :: [(String, String)]
named_characters = [("comma", ","), ("space", " "), ("colon", ":"), ("semicolon", ";"), ("ampersand", "&"), ("tilde", "~"), ("slash", "/"), ("backslash", "\\")]

instance Parse String where
  parse = label "verbatim string" $ (select cs <||>) $
    Parser (Terminators False [] []) $ \t _ -> quoted <|> unquoted t
   where
    quoted = char '`' >> fmap Right (many $ satisfy (/= '`')) << char '`' << spaces
    unquoted t = fmap (Right . NeList.to_plain . fst) $ many1Till (P.silent anySymbol) $ try $ apply_if (term_eof t) (eof <|>) $ lookAhead
      (choice ((\k -> try $ symbols (' ': k) >> (eof <|> P.char_unit ' ')) `fmap` term_keywords t)) >> P.char_unit ' '
    cs :: [([String], String)]
    cs = map (\(x, y) -> ([plural x, x, (if isVowel (head x) then "an " else "a ") ++ x], y)) named_characters

instance Parse a => Parse (AndList a) where
  parse = liftA2 NeList parse ((and parse >>> arr (NeList.to_plain . andList)) <||> arr (const [])) >>> arr AndList

and :: Parser x a -> Parser x a
and (Parser (Terminators _ t _) p) = Parser (Terminators False ["and"] t) $
  \t' x -> try $ do
    symbols "and "
    notFollowedBy (choice $ try `fmap` symbols `fmap` (and_conts t'))
    p t' x

instance (Parse a, Parse b) => Parse (Either a b) where parse = (parse >>> arr Left) <||> (parse >>> arr Right)

semipure :: (a -> Either String b) -> Parser a b
semipure f = Parser (Terminators True [] []) $ \_ -> return . f

select :: [([String], a)] -> Parser x a
select = foldl1 (<||>) . map (\(s, r) -> if null s then arr (const r) else kwd s >>> arr (const r))

optional :: Parser a b -> Parser a ()
optional p = (p >>> arr (const ())) <||> arr (const ())

option :: Parser a b -> Parser a (Maybe b)
option p = (p >>> arr Just) <||> arr (const Nothing)

auto1 :: Parse a => (a -> b) -> Parser x b
auto1 f = parse >>> arr f

auto2 :: (Parse a, Parse b) => (a -> b -> c) -> Parser x c
auto2 f = proc x -> do a <- parse -< x; b <- parse -< x; returnA -< f a b

till, begin, end_kwds :: [String]
till = ["till", "until"]
begin = ["beginning", "begin", "front", "start"]
end_kwds = ["end", "back"]

instance Parse a => Parse (Ranked a) where parse = auto2 Ranked <||> auto1 Sole

instance Parse BefAft where parse = select [(["before"], Before), (["after"], After)]

instance Parse RelativeBound where
  parse = select [(end_kwds, Back), (begin, Front)] <||> auto2 RelativeBound

instance Parse Ordinal where
  parse = label "ordinal" $ (>>> arr Ordinal) $ proc _ -> do
    optional $ kwd ["the"] -< ()
    (select [(["last"], -1), (["first"], 0)] -< ()) <||> do
    n <- select $ fmap (\n -> ([show (Ordinal n)], n)) [1..9] -< ()
    b <- select [(["last"], True), ([], False)] -< ()
    returnA -< if b then - n - 1 else n

parseSmallPositiveCardinal :: Parser a Int
parseSmallPositiveCardinal = select $ map (\(x,y) -> ([x {-, show y-}], y)) $ tail $ zip cardinals [0..]

instance Parse OccurrencesClause where
  parse = label "ordinal" $ (>>> arr OccurrencesClause) $  -- Todo: FIx inappropriate label.
    (optional (kwd ["the"]) >>> kwd ["first"] >>> parseSmallPositiveCardinal >>> arr (\n -> fmap Ordinal $ NeList 0 [1 .. n-1])) <||>
    (optional (kwd ["the"]) >>> kwd ["last"] >>> parseSmallPositiveCardinal >>> arr (\n -> fmap Ordinal $ NeList (-1) [-n .. -2])) <||>
    auto1 NeList.one

instance Parse a => Parse (EverythingOr a) where
  parse = select [(["everything"], Everything)] <||> auto1 NotEverything

relative :: Parser a (Relative a)
relative = proc a -> do x <- parse -< (); y <- parse -< (); returnA -< Relative a x y
  <||> do b <- parse -< (); returnA -< Between a b
  <||> do returnA -< Absolute a

instance Parse a => Parse (In a) where parse = auto2 In

instance Parse Bound where parse = select [(begin, front), (end_kwds, back)] <||> auto2 Bound

instance Parse Betw where
  parse = (kwd ["between"] >>>) $ proc _ -> do
      y <- parse -< ()
      do
        rank' <- and parse -< (); s <- parse -< ()
        returnA -< Betw (Bound Nothing $ NotEverything $ Ranked y s) $ RelativeBound Nothing $ Absolute $ NotEverything $ Ranked rank' s
       <||> do
        x <- parse -< (); v <- and parse -< ()
        returnA -< Betw (Bound Nothing (NotEverything $ Ranked y x)) v
    <||> do liftA2 Betw (parse) (and parse) -< ()

relative_everything_orA :: Parser y (Relative (EverythingOr a))
relative_everything_orA =
    (kwd till >>> auto1 (Between Everything . Betw front))
  <||> liftA2 FromTill (kwd ["from"] >>> parse) ((kwd till >>> parse) <||> arr (const Back))
  <||> (kwd ["everything"] >>>
    (liftA2 (\x y -> Between Everything (Betw x y)) (kwd ["from"] >>> parse) (kwd till >>> parse)
      <||> (kwd till >>> auto1 (\x -> Between Everything (Betw front x)))
      <||> (arr (const Everything) >>> relative)))
  <||> (proc _ -> do
    kwd ["before"] -< ()
    y <- auto1 NotEverything -< ()
    x <- do z <- kwd till >>> parse -< (); returnA -< Betw (Bound (Just Before) y) z
      <||> do returnA -< Betw front $ RelativeBound (Just Before) $ Absolute y
    returnA -< Between Everything x)
  <||> auto1 (Between Everything)
  <||> proc _ -> do
    x <- kwd ["after"] >>> parse -< ()
    y <- (kwd till >>> parse -< ()) <||> (returnA -< Back)
    returnA -< Between Everything (Betw (Bound (Just After) x) y)

instance Parse (Relative Substr) where
  parse = (relative_everything_orA <||>) $ parse >>> proc x -> do
      u <- kwd till >>> parse -< ()
      returnA -< Between Everything $ Betw (Bound (Just Before) $ NotEverything x) u
    <||> (relative -< NotEverything x)

instance Parse (Relative (Ranked Cxx.Basics.Findable)) where parse = parse >>> relative
instance Parse (Relative (Rankeds (Either Cxx.Basics.Findable DeclaratorId))) where parse = parse >>> relative

instance Parse (Relative (EverythingOr (Rankeds (Either Cxx.Basics.Findable String)))) where
  parse = (relative_everything_orA <||>) $ (parse >>>) $ proc x -> case x of
    Rankeds (AndList (NeList (OccurrencesClause (NeList r [])) [])) s -> do
        u <- kwd till >>> parse -< ()
        returnA -< Between Everything (Betw (Bound (Just Before) $ NotEverything $ Ranked r s) u)
      <||> (relative -< NotEverything x)
    Sole' s -> do
        u <- kwd till >>> parse -< ()
        returnA -< Between Everything (Betw (Bound (Just Before) $ NotEverything $ Sole s) u)
      <||> (relative -< NotEverything x)
    _ -> (relative -< NotEverything x)

with_plurals :: [String] -> [String]
with_plurals l = map (++"s") l ++ l

instance Parse Cxx.Basics.Findable where
  parse =
    ((label "\"declaration\"" $ kwd ["declarations", "declaration"]) >>> kwd ["of"] >>> auto1 Cxx.Basics.DeclarationOf) <||>
    ((label "\"body\"" $ kwd ["bodies", "body"]) >>> kwd ["of"] >>> auto1 Cxx.Basics.BodyOf) <||>
    label "production-name" (
      auto1 Cxx.Basics.FindableDataType <||>
      auto1 Cxx.Basics.FindableConstr <||>
      (kwd (with_plurals ["constructor", "ctor"]) >>> arr (const Cxx.Basics.Constructor)) <||>
      (kwd (with_plurals ["destructor", "dtor"]) >>> arr (const Cxx.Basics.Destructor)) <||>
      (kwd (with_plurals ["conversion-function"]) >>> arr (const Cxx.Basics.ConversionFunction)))

class Constructor a where to_constr :: a -> Constr
instance Data a => Constructor a where to_constr x = toConstr x
instance Constructor b => Constructor (a -> b) where to_constr f = to_constr $ f undefined

instance Parse DataType where
  parse = select $ map (\t -> (with_plurals [show $ Cxx.Basics.FindableDataType t], t)) Cxx.Operations.productions

instance Parse Constr where
  parse = select $ map (\c -> (with_plurals [show $ Cxx.Basics.FindableConstr c], c))
#define P(n) to_constr Cxx.Basics.n
    [ P(BooleanLiteral), P(PointerLiteral), P(IfStatement), P(SwitchStatement), P(WhileStatement), P(DoWhileStatement)
    , P(ForStatement), P(BreakStatement), P(ContinueStatement), P(ReturnStatement), P(GotoStatement) ]
#undef P

instance Parse Position where
  parse = (select [(begin, Before), (end_kwds, After)] >>> arr (flip Position $ flip In Nothing $ Absolute Everything)) <||> auto2 Position

instance Parse a => Parse (Rankeds a) where
  parse = (kwd ["all"] >>> ((kwd ["except", "but"] >>> auto2 AllBut) <||> auto1 All))
    <||> (kwd ["any", "every", "each"] >>> auto1 All) <||> auto2 Rankeds <||> auto1 Sole'

instance Parse InClause where parse = kwd ["in"] >>> auto1 InClause

instance Parse AppendPositionsClause where
  parse = auto1 AppendIn <||> auto1 NonAppendPositionsClause
instance Parse PrependPositionsClause where
  parse = auto1 PrependIn <||> auto1 NonPrependPositionsClause

instance Parse Substrs where parse = auto1 Substrs

instance Parse PositionsClause where
  parse = (kwd ["at"] >>> select [(begin, Before), (end_kwds, After)] >>> arr (\ba -> PositionsClause ba $ Substrs $ and_one $ flip In Nothing $ Absolute Everything)) <||> auto2 PositionsClause

instance Parse Replacer where
  parse = liftA2 ReplaceOptions parse (wb >>> parse) <||> liftA2 Replacer parse (wb >>> parse)
    where wb = kwd ["with", "by"]

instance Parse Changer where
  parse = liftA2 ChangeOptions parse (wb >>> parse) <||> liftA2 Changer parse (wb >>> parse)
    where wb = kwd ["to"]

instance Parse Eraser where parse = auto2 EraseAround <||> auto1 EraseOptions <||> auto1 EraseText
instance Parse Mover where parse = liftA2 Mover parse (kwd ["to"] >>> parse)
instance Parse [EvalOpt] where parse = Parser (Terminators False [] []) $ \_ _ -> optParser
instance Parse a => Parse (Around a) where parse = kwd ["around"] >>> auto1 Around
instance Parse UsePattern where parse = auto1 UsePattern
instance Parse (Relative UsePattern) where parse = parse >>> relative

instance Parse UseClause where parse = auto1 UseOptions <||> (parse {- >>> relative-} >>> arr UseString)

namedWrappings :: [([String], Wrapping)]
namedWrappings =
  [ (["curlies", "braces", "curly brackets"], Wrapping "{" "}")
  , (["parentheses", "parens", "round brackets"], Wrapping "(" ")")
  , (["square brackets"], Wrapping "[" "]")
  , (["angle brackets"], Wrapping "<" ">")
  , (["single quotes"], Wrapping "'" "'")
  , (["double quotes"], Wrapping "\"" "\"")
  , (["spaces"], Wrapping " " " ") ]

instance Parse Wrapping where
  parse = label "wrapping description" $ select namedWrappings <||> liftA2 Wrapping parse (and parse)

instance Parse a => Parse (Maybe a) where parse = (parse >>> arr Just) <||> arr (const Nothing)

instance Parse Command where
  parse = label "edit command" $
    (kwd ["insert", "add"] >>> commit ((parse >>> arr (Use `fmap` (fmap UseOptions))) <||> auto2 Insert <||> auto2 WrapAround)) <||>
    (kwd ["append"] >>> commit (auto2 Append)) <||>
    (kwd ["prepend"] >>> commit ((parse >>> arr (Use `fmap` (fmap UseOptions))) <||> auto2 Prepend)) <||>
    (kwd ["erase", "remove", "kill", "cut", "omit", "delete", "drop"] >>> commit (auto1 Erase)) <||>
    (kwd ["replace"] >>> commit (auto1 Replace)) <||>
    (kwd ["change"] >>> commit (auto1 Change)) <||>
    (kwd ["use"] >>> commit (auto1 Use)) <||>
    (kwd ["move"] >>> commit (auto1 Move)) <||>
    (kwd ["swap"] >>> commit (liftA2 Swap parse (option (kwd ["with"] >>> parse)))) <||>
    (kwd ["wrap"] >>> commit (parse >>> snd_unit (auto1 Left <||> (kwd ["in"] >>> auto1 Right)) >>> semipure (uncurry wc)))
    where
      wc :: Substrs -> Either (AndList (Around Substrs)) Wrapping -> Either String Command
      wc what (Right wrapping) = return $ WrapIn what wrapping
      wc (Substrs (AndList (NeList (In (Absolute (NotEverything (Sole' (Right x)))) Nothing) []))) (Left what) =
        (\q -> WrapAround q what) `fmap` case fmap snd $ List.find (elem x . fst) namedWrappings of
          Just w -> return w
          Nothing -> fail "Unrecognized wrapping description."
      wc (Substrs (AndList (NeList (In (Absolute (NotEverything (Sole' (Right x)))) Nothing)
        [In (Absolute (NotEverything (Sole' (Right y)))) Nothing]))) (Left what) =
          return $ WrapAround (Wrapping x y) what
      wc _ (Left _) = fail "Malformed wrap command."

instance Parse Cxx.Basics.MakeDeclaration where
  parse = Parser (Terminators False [] []) $ \_ _ -> Right `fmap` Cxx.Parse.makeDeclParser

instance Parse DeclaratorId where
  parse = Parser (Terminators False [] []) $ \_ _ -> Right `fmap` Cxx.Parse.declaratorIdParser

instance Parse MakeClause where parse = auto2 MakeClause

instance Parse SemCommand where
  parse = label "edit command" $ kwd ["make"] >>> commit (auto1 Make)

instance Parse FinalCommand where
  parse = label "edit command" $
    (kwd ["show", "display"] >>> commit (option parse >>> arr Show)) <||>
    (kwd ["identify"] >>> commit (auto1 Identify)) <||>
    (kwd ["parse"] >>> arr (const Parse))

instance Parse (([Command], [SemCommand]), Maybe FinalCommand) where
  parse = liftA2 (,) (parse >>> arr (partitionEithers . NeList.to_plain . andList)) (option $ and parse)

uncool :: Parser () a -> Terminators -> P.Parser Char (Either String a)
uncool (Parser _ f) t = f t ()

commandsP :: P.Parser Char (Either String (([Command], [SemCommand]), Maybe FinalCommand))
commandsP = uncool parse $ Terminators True [] []

finalCommandP :: P.Parser Char (Either String FinalCommand)
finalCommandP = uncool parse $ Terminators True [] []
