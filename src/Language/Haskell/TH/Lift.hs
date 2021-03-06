{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeSynonymInstances #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Language.Haskell.TH.Lift
  ( deriveLift
  , deriveLiftMany
  , deriveLift'
  , deriveLiftMany'
  , makeLift
  , makeLift'
  , Lift(..)
  ) where

#if !(MIN_VERSION_template_haskell(2,4,0))
import Data.PackedString (PackedString, packString, unpackPS)
#endif /* MIN_VERSION_template_haskell(2,4,0) */

import GHC.Base (unpackCString#)
import GHC.Exts (Double(..), Float(..), Int(..), Word(..))
import GHC.Prim (Addr#, Double#, Float#, Int#, Word#)
#if MIN_VERSION_template_haskell(2,11,0)
import GHC.Exts (Char(..))
import GHC.Prim (Char#)
#endif /* !(MIN_VERSION_template_haskell(2,11,0)) */

import Control.Applicative
#if MIN_VERSION_template_haskell(2,8,0)
import Data.Char (ord)
#endif /* !(MIN_VERSION_template_haskell(2,8,0)) */
#if MIN_VERSION_base(4,8,0)
import Data.Functor.Identity
#endif
#if !(MIN_VERSION_template_haskell(2,10,0))
import Data.Ratio (Ratio)
#endif /* !(MIN_VERSION_template_haskell(2,10,0)) */
import Language.Haskell.TH
import Language.Haskell.TH.Datatype
import qualified Language.Haskell.TH.Lib as Lib (starK)
import Language.Haskell.TH.Syntax
import Control.Monad ((<=<), zipWithM)
#if MIN_VERSION_template_haskell(2,9,0)
import Data.Maybe (catMaybes)
#endif /* MIN_VERSION_template_haskell(2,9,0) */

-- | Derive Lift instances for the given datatype.
deriveLift :: Name -> Q [Dec]
#if MIN_VERSION_template_haskell(2,9,0)
deriveLift name = do
  roles <- reifyDatatypeRoles name
  info <- reifyDatatype name
  fmap (:[]) $ deriveLiftOne roles info
#else
deriveLift = fmap (:[]) . deriveLiftOne <=< reifyDatatype
#endif

-- | Derive Lift instances for many datatypes.
deriveLiftMany :: [Name] -> Q [Dec]
#if MIN_VERSION_template_haskell(2,9,0)
deriveLiftMany names = do
  roles <- mapM reifyDatatypeRoles names
  infos <- mapM reifyDatatype names
  mapM (uncurry deriveLiftOne) $ zip roles infos
#else
deriveLiftMany = mapM deriveLiftOne <=< mapM reifyDatatype
#endif

-- | Obtain Info values through a custom reification function. This is useful
-- when generating instances for datatypes that have not yet been declared.
#if MIN_VERSION_template_haskell(2,9,0)
deriveLift' :: [Role] -> Info -> Q [Dec]
deriveLift' roles = fmap (:[]) . deriveLiftOne roles <=< normalizeInfo

deriveLiftMany' :: [([Role], Info)] -> Q [Dec]
deriveLiftMany' = mapM (\(rs, i) -> deriveLiftOne rs =<< normalizeInfo i)
#else
deriveLift' :: Info -> Q [Dec]
deriveLift' = fmap (:[]) . deriveLiftOne <=< normalizeInfo

deriveLiftMany' :: [Info] -> Q [Dec]
deriveLiftMany' = mapM (deriveLiftOne <=< normalizeInfo)
#endif

-- | Generates a lambda expresson which behaves like 'lift' (without requiring
-- a 'Lift' instance). Example:
--
-- @
-- newtype Fix f = In { out :: f (Fix f) }
--
-- instance Lift (f (Fix f)) => Lift (Fix f) where
--   lift = $(makeLift ''Fix)
-- @
makeLift :: Name -> Q Exp
makeLift = makeLiftInternal <=< reifyDatatype

-- | Like 'makeLift', but using a custom reification function.
makeLift' :: Info -> Q Exp
makeLift' = makeLiftInternal <=< normalizeInfo

makeLiftInternal :: DatatypeInfo -> Q Exp
makeLiftInternal i = withInfo i $ \_ n _ cons -> makeLiftOne n cons

#if MIN_VERSION_template_haskell(2,9,0)
deriveLiftOne :: [Role] -> DatatypeInfo -> Q Dec
deriveLiftOne roles i = withInfo i liftInstance
#else
deriveLiftOne :: DatatypeInfo -> Q Dec
deriveLiftOne i = withInfo i liftInstance
#endif
  where
    liftInstance dcx n tys cons = do
#if MIN_VERSION_template_haskell(2,9,0)
      -- roles <- reifyDatatypeRoles n
      -- Compute the set of phantom variables.
      let phtys = catMaybes $
            zipWith (\t role -> if role == PhantomR then Just t else Nothing)
                    tys
                    roles
#else /* MIN_VERSION_template_haskell(2,9,0) */
      let phtys = []
#endif
      instanceD (ctxt dcx phtys tys)
                (conT ''Lift `appT` typ n tys)
                [funD 'lift [clause [] (normalB (makeLiftOne n cons)) []]]
    typ n = foldl appT (conT n) . map unKind
    -- Only consider *-kinded type variables, because Lift instances cannot
    -- meaningfully be given to types of other kinds. Further, filter out type
    -- variables that are obviously phantom.
    ctxt dcx phtys =
        fmap (dcx ++) . cxt . concatMap liftPred . filter (`notElem` phtys)
    liftPred ty =
      case ty of
        SigT t k
          | k == Lib.starK -> mkLift t
          | otherwise      -> []
        _                  -> mkLift ty
#if MIN_VERSION_template_haskell(2,10,0)
    mkLift ty = [conT ''Lift `appT` (return ty)]
#else
    mkLift ty = [classP ''Lift [return ty]]
#endif
    unKind (SigT t k)
      | k == Lib.starK = return t
    unKind t           = return t

makeLiftOne :: Name -> [ConstructorInfo] -> Q Exp
makeLiftOne n cons = do
  e <- newName "e"
  lam1E (varP e) $ caseE (varE e) $ consMatches n cons

consMatches :: Name -> [ConstructorInfo] -> [Q Match]
consMatches n [] = [match wildP (normalB e) []]
  where
    e = [| errorQExp $(stringE ("Can't lift value of empty datatype " ++ nameBase n)) |]
consMatches _ cons = concatMap doCons cons

doCons :: ConstructorInfo -> [Q Match]
doCons (ConstructorInfo { constructorName    = c
                        , constructorFields  = ts
                        , constructorVariant = variant
                        }) = (:[]) $ do
    ns <- zipWithM (\_ i -> newName ('x':show (i :: Int))) ts [0..]
    let con = [| conE c |]
    case (variant, ns, ts) of
      (InfixConstructor, [x0, x1], [t0, t1]) ->
        let e = [| infixApp $(liftVar x0 t0) $con $(liftVar x1 t1) |]
        in match (infixP (varP x0) c (varP x1)) (normalB e) []
      (_, _, _) ->
        let e = foldl (\e1 e2 -> [| appE $e1 $e2 |]) con $ zipWith liftVar ns ts
        in match (conP c (map varP ns)) (normalB e) []

#if MIN_VERSION_template_haskell(2,9,0)
-- Reify the roles of a data type. Note that the argument Name may correspond
-- to that of a data family instance constructor, so we need to go through
-- reifyDatatype to determine what the parent data family Name is.
reifyDatatypeRoles :: Name -> Q [Role]
reifyDatatypeRoles n = do
  DatatypeInfo { datatypeName = dn } <- reifyDatatype n
  qReifyRoles dn
#endif

liftVar :: Name -> Type -> Q Exp
liftVar varName (ConT tyName)
#if MIN_VERSION_template_haskell(2,8,0)
  | tyName == ''Addr#   = [| litE (stringPrimL (map (fromIntegral . ord)
                                                    (unpackCString# $var))) |]
#else /* !(MIN_VERSION_template_haskell(2,8,0)) */
  | tyName == ''Addr#   = [| litE (stringPrimL (unpackCString# $var))       |]
#endif
#if MIN_VERSION_template_haskell(2,11,0)
  | tyName == ''Char#   = [| litE (charPrimL               (C# $var))  |]
#endif  /* !(MIN_VERSION_template_haskell(2,11,0)) */
  | tyName == ''Double# = [| litE (doublePrimL (toRational (D# $var))) |]
  | tyName == ''Float#  = [| litE (floatPrimL  (toRational (F# $var))) |]
  | tyName == ''Int#    = [| litE (intPrimL    (toInteger  (I# $var))) |]
  | tyName == ''Word#   = [| litE (wordPrimL   (toInteger  (W# $var))) |]
  where
    var :: Q Exp
    var = varE varName
liftVar varName _ = [| lift $(varE varName) |]

withInfo :: DatatypeInfo
         -> (Cxt -> Name -> [Type] -> [ConstructorInfo] -> Q a)
         -> Q a
withInfo i f = case i of
    DatatypeInfo { datatypeContext = dcx
                 , datatypeName    = n
                 , datatypeVars    = vs
                 , datatypeCons    = cons
                 } ->
      f dcx n vs cons

-- A type-restricted version of error that ensures makeLift always returns a
-- value of type Q Exp, even when used on an empty datatype.
errorQExp :: String -> Q Exp
errorQExp = error
{-# INLINE errorQExp #-}

instance Lift Name where
  lift (Name occName nameFlavour) = [| Name occName nameFlavour |]

#if MIN_VERSION_template_haskell(2,4,0)
instance Lift OccName where
  lift n = [| mkOccName $(lift $ occString n) |]

instance Lift PkgName where
  lift n = [| mkPkgName $(lift $ pkgString n) |]

instance Lift ModName where
  lift n = [| mkModName $(lift $ modString n) |]

#else /* MIN_VERSION_template_haskell(2,4,0) */
instance Lift PackedString where
  lift ps = [| packString $(lift $ unpackPS ps) |]

#endif /* MIN_VERSION_template_haskell(2,4,0) */
instance Lift NameFlavour where
  lift NameS = [| NameS |]
  lift (NameQ modnam) = [| NameQ modnam |]
#if __GLASGOW_HASKELL__ >= 710
  lift (NameU i) = [| NameU i |]
  lift (NameL i) = [| NameL i |]
#else /* __GLASGOW_HASKELL__ < 710 */
  lift (NameU i) = [| case $( lift (I# i) ) of
                          I# i' -> NameU i' |]
  lift (NameL i) = [| case $( lift (I# i) ) of
                          I# i' -> NameL i' |]
#endif /* __GLASGOW_HASKELL__ < 710 */
  lift (NameG nameSpace' pkgName modnam)
   = [| NameG nameSpace' pkgName modnam |]

instance Lift NameSpace where
  lift VarName = [| VarName |]
  lift DataName = [| DataName |]
  lift TcClsName = [| TcClsName |]

#if !(MIN_VERSION_template_haskell(2,10,0))
-- These instances should really go in the template-haskell package.

instance Lift () where
  lift _ = [| () |]

instance Integral a => Lift (Ratio a) where
  lift x = return (LitE (RationalL (toRational x)))
#endif

#if MIN_VERSION_base(4,8,0)
instance Lift a => Lift (Identity a) where
  lift = appE (conE 'Identity) . lift . runIdentity
#endif

instance Lift a => Lift (Const a b) where
  lift = appE (conE 'Const) . lift . getConst
