{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE TupleSections #-}

module W2M where

import Data.Bits
import Data.ByteString.Lazy qualified as BS
import Data.Foldable
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (catMaybes, maybeToList)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text.Lazy (Text, replace)
import Data.Vector.Unboxed (Vector)
import Data.Vector.Unboxed qualified as V
import Data.Word (Word8, Word32)
import GHC.Natural (Natural)
import Language.Wasm.Structure qualified as W

import MASM qualified as M
import MASM.Interpreter (toFakeW64, FakeW64 (..))
import Validation
import Control.Monad.Except
import W2M.Stack
import Control.Applicative

type WasmAddr = Natural
type MasmAddr = Word32
type LocalAddrs = Map WasmAddr (StackElem, [MasmAddr])

funName :: Id -> String
funName i = "fun" ++ show i

toMASM :: Bool -> W.Module -> V M.Module
toMASM checkImports m = do
  -- TODO: don't throw away main's type, we might want to check it and inform how the program can be called?
  when checkImports $ checkImps (W.imports m)
  globalsInit <- getGlobalsInit
  datasInit <- getDatasInit

  M.Module ["std::sys", "std::math::u64"]
    <$> fmap catMaybes (traverse fun2MASM sortedFuns)
    <*> return (M.Program (globalsInit ++ datasInit ++ [ M.Exec "main" ] ++ stackCleanUp))

  where checkImps xs
          | checkImports = traverse_ (\(W.Import imodule iname idesc) -> badImport imodule iname $ descType idesc) xs
          | otherwise    = return ()

        descType idesc = case idesc of
          W.ImportFunc _t -> "function"
          W.ImportTable _t -> "table"
          W.ImportMemory _l -> "memory"
          W.ImportGlobal _g -> "global"

        globalsAddrMap :: Vector MasmAddr
        memBeginning :: MasmAddr
        (globalsAddrMap, memBeginning) = (\(xs, n) -> (V.fromList xs, n)) $ foldl' f ([], 0) (W.globals m)
          where f (xs, n) globl_i =
                  let ncells = case W.globalType globl_i of
                                 W.Const t -> numCells t
                                 W.Mut   t -> numCells t
                  in (xs ++ [n], n+ncells)

        callGraph :: Map Text (Set Text)
        callGraph = Map.unionsWith (<>)
          [ Map.singleton caller (Set.singleton callee)
          | (caller, W.Function _ _ instrs) <- Map.toList functionsMap
          , W.Call k <- instrs
          , callee <- maybeToList $ Map.lookup (fromIntegral k) functionNamesMap
          ]

        enumerate x = x : concatMap enumerate [ y | y <- maybe [] Set.toList (Map.lookup x callGraph) ]
        sortedFuns = catMaybes . map (\fn -> (fn,) <$> Map.lookup fn functionsMap) $ 
          let xs = enumerate "main"
              rxs = reverse xs
              go [] _ = []
              go (a:as) !visited
                | a `Set.member` visited = go as visited
                | otherwise = a : go as (Set.insert a visited)
          in go rxs Set.empty

        numCells :: W.ValueType -> Word32
        numCells t = case t of
          W.I32 -> 1
          W.I64 -> 2
          _ -> error "numCells called on non integer value type"

        getDatasInit :: V [M.Instruction]
        getDatasInit = concat <$> traverse getDataInit (W.datas m)
        
        getDataInit :: W.DataSegment -> V [M.Instruction]
        getDataInit (W.DataSegment 0 offset_wexpr bytes) = do
          offset_mexpr <- translateInstrs [] mempty offset_wexpr
          pure $ offset_mexpr ++
                 [ M.Push 4, M.IDiv             -- [offset_bytes/4, ...]
                 , M.Push memBeginning, M.IAdd  -- [offset_bytes/4+memBeginning, ...] =
                 ] ++                           -- [addr_u32, ...]
                 writeW32s (BS.unpack bytes) ++ -- [addr_u32+len(bytes)/4, ...]
                 [ M.Drop ]                     -- [...]
        getDataInit _ = badNoMultipleMem

        writeW32s :: [Word8] -> [M.Instruction]
        writeW32s [] = []
        writeW32s (a:b:c:d:xs) =
          let w = foldl' (.|.) 0 [ shiftL (fromIntegral x) (8 * i)
                                 | (i, x) <- zip [0..] [a,b,c,d]
                                 ]
          in [ M.Dup 0 -- [addr_u32, addr_u32, ...]
             , M.Push w -- [w, addr_u32, addr_u32, ...]
             , M.Swap 1 -- [addr_u32, w, addr_u32, ...]
             , M.MemStore Nothing -- [w, addr_u32, ...]
             , M.Drop -- [addr_u32, ...]
             , M.Push 1, M.IAdd -- [addr_u32+1, ...]
             ] ++ writeW32s xs
        writeW32s xs = writeW32s $ xs ++ replicate (4-length xs) 0

        getGlobalsInit :: V [M.Instruction]
        getGlobalsInit = concat <$> traverse getGlobalInit (zip [0..] (W.globals m))

        getGlobalInit :: (Int, W.Global) -> V [M.Instruction]
        getGlobalInit (k, g) = do
          xs <- translateInstrs [] mempty (W.initializer g ++ [W.SetGlobal $ fromIntegral k])
          return xs

        getGlobalTy k = case t of
            W.I32 -> SI32
            W.I64 -> SI64
            _     -> error "unsupported global type"

          where t = case W.globalType (W.globals m !! fromIntegral k) of
                      W.Const ct -> ct
                      W.Mut mt -> mt

        functionsMap :: Map Text W.Function
        functionsMap = Map.fromList
          [ (fixName fname, W.functions m !! fromIntegral i)
          | W.Export fname (W.ExportFunc i) <- W.exports m
          ]

        emptyFunctions :: Set Text
        emptyFunctions = Set.fromList
          [ fname
          | (fname, W.Function _ _ []) <- Map.toList functionsMap
          ]

        functionNamesMap :: Map Int Text
        functionNamesMap = Map.fromList
          [ (fromIntegral i, fixName fname)
          | W.Export fname (W.ExportFunc i) <- W.exports m
          ]

        functionTypesMap :: Map Text W.FuncType
        functionTypesMap =
          fmap (\(W.Function tyIdx _ _) -> W.types m !! fromIntegral tyIdx) functionsMap

        fixName = replace "__" "zz__"

        fun2MASM :: (Text, W.Function) -> V (Maybe M.Proc)
        fun2MASM (_fname, W.Function _         _         []) = return Nothing
        fun2MASM (fname, W.Function _funTyIdx localsTys body) = do
          let wasm_args = maybe [] W.params (Map.lookup fname functionTypesMap)
              wasm_locals = localsTys

              localAddrMap :: LocalAddrs
              (localAddrMap, nlocalCells) =
                foldl' (\(addrs, cnt) (k, ty) -> case ty of
                           W.I32 -> (Map.insert k (SI32, [cnt]) addrs, cnt+1)
                           W.I64 -> (Map.insert k (SI64, [cnt, cnt+1]) addrs, cnt+2)
                           _     -> error $ "localAddrMap: floating point local var?"
                       )
                       (Map.empty, 0)
                       (zip [0..] (wasm_args ++ wasm_locals))
              -- the function starts by populating the first nargs local vars
              -- with the topmost nargs values on the stack, removing them from
              -- the stack as it goes. it assumes the value for the first arg
              -- was pushed first, etc, with the value for the last argument
              -- being pushed last and therefore popped first.

              prelude = reverse $ concat 
                [ case Map.lookup (fromIntegral k) localAddrMap of
                    Just (_t, is) -> concat [ [ M.Drop, M.LocStore i ] | i <- is ]
                    _ -> error ("impossible: prelude of procedure " ++ show fname ++ ", local variable " ++ show k ++ " not found?!")
                | k <- [0..(length wasm_args - 1)]
                ]

          argsStack <- checkTypes wasm_args
          instrs <- translateInstrs argsStack localAddrMap body
          return $ Just (M.Proc fname (fromIntegral nlocalCells) (prelude ++ instrs))


        translateInstrs :: StackType -> LocalAddrs -> W.Expression -> V [M.Instruction]
        translateInstrs stack0 locals wasmInstrs = do
          -- we do this in two steps so that we can report e.g unsupported instructions
          -- or calls to unexisting functions "applicatively" and add some additional sequential
          -- reporting logic that tracks the type of the stack and allows 'translateInstr' to
          -- inspect the stack to bail out if they're not right and otherwise
          -- use the types of the stack values to drive the MASM code generation.
          stackFuns <- traverse (translateInstr locals) wasmInstrs
          case foldStackFuns stack0 stackFuns of
            Left e -> badStackTypeError e
            Right (a, _finalT) -> return (concat a)

        translateInstr :: LocalAddrs -> W.Instruction Natural -> V (StackFun [M.Instruction])
        translateInstr _ inst@(W.Call i) = case Map.lookup (fromIntegral i) functionNamesMap of
          Nothing -> badWasmFunctionCallIdx (fromIntegral i)
          Just fname
            | fname `Set.notMember` emptyFunctions ->
                case Map.lookup fname functionTypesMap of
                  Just (W.FuncType params res) -> do
                    params' <- checkTypes params
                    res' <- checkTypes res
                    return $ assumingPrefix inst params' $ \t -> ([M.Exec fname], res' ++ t)
                  Nothing -> badWasmFunctionCallIdx (fromIntegral i)

            | otherwise -> pure (pure [])
        translateInstr _ (W.I32Const w32) = pure $ noPrefix $ \t -> ([M.Push w32], SI32:t)
        translateInstr _ (W.IBinOp bitsz op) = translateIBinOp bitsz op
        translateInstr _ i@W.I32Eqz = pure $
          assumingPrefix i [SI32] $ \t -> ([M.IEq (Just 0)], SI32:t)
        translateInstr _ (W.IRelOp bitsz op) = translateIRelOp bitsz op
        translateInstr _ i@W.Select = return $
          assumingPrefix i [SI32, SI32, SI32] $ \t ->
            ([M.IfTrue [M.Drop] [M.Swap 1, M.Drop]], SI32:t)
        translateInstr _ i@(W.I32Load (W.MemArg offset align)) = case align of
          2 -> pure $
            assumingPrefix i [SI32] $ \t -> 
                 ( [ M.Push 4
                   , M.IDiv
                   , M.Push (fromIntegral offset `div` 4)
                   , M.IAdd
                   , M.Push memBeginning
                   , M.IAdd
                   , M.MemLoad Nothing
                   ]
                 , SI32:t
                 )
          _ -> unsupportedMemAlign align
        translateInstr _ i@(W.I32Store (W.MemArg offset align)) = case align of
          -- we need to turn [val, byte_addr, ...] of wasm into [u32_addr, val, ...]
          2 -> pure $ 
            assumingPrefix i [SI32, SI32] $ \t ->
                 ( [ M.Swap 1
                   , M.Push 4
                   , M.IDiv
                   , M.Push (fromIntegral offset `div` 4)
                   , M.IAdd
                   , M.Push memBeginning
                   , M.IAdd
                   , M.MemStore Nothing
                   , M.Drop
                   ]
                 , t
                 )
          _ -> unsupportedMemAlign align
        translateInstr localAddrs (W.GetLocal k) = case Map.lookup k localAddrs of
          Just (loct, is) -> pure $ noPrefix $ \t -> (map M.LocLoad is, loct:t)
          _ -> error ("impossible: local variable " ++ show k ++ " not found?!")

        translateInstr localAddrs i@(W.SetLocal k) = case Map.lookup k localAddrs of
          Just (loct, as) -> pure $
            assumingPrefix i [loct] $ \t -> 
              ( concat
                  [ [ M.LocStore a
                    , M.Drop
                    ]
                  | a <- reverse as
                  ]
              , t
              )
          _ -> error ("impossible: local variable " ++ show k ++ " not found?!")
        translateInstr localAddrs (W.TeeLocal k) =
          liftA2 (++) <$> translateInstr localAddrs (W.SetLocal k)
                      <*> translateInstr localAddrs (W.GetLocal k)

        translateInstr _ (W.GetGlobal k) = case getGlobalTy k of
          SI32 -> pure $ noPrefix $ \t ->
            ( [ M.MemLoad . Just $ globalsAddrMap V.! fromIntegral k
              ]
            , SI32:t
            )
          SI64 -> pure $ noPrefix $ \t ->
            ( [ M.MemLoad . Just $ globalsAddrMap V.! fromIntegral k
              , M.MemLoad . Just $ (globalsAddrMap V.! fromIntegral k) + 1
              ]
            , SI64:t
            )
        translateInstr _ i@(W.SetGlobal k) = case getGlobalTy k of
          SI32 -> pure $ assumingPrefix i [SI32] $ \t ->
            ( [ M.MemStore . Just $ globalsAddrMap V.! fromIntegral k 
              , M.Drop
              ]
            , t
            )
          SI64 -> pure $ assumingPrefix i [SI64] $ \t -> 
            ( [ M.MemStore . Just $ (globalsAddrMap V.! fromIntegral k) + 1
              , M.Drop
              , M.MemStore . Just $ (globalsAddrMap V.! fromIntegral k)
              , M.Drop
              ]
            , t
            )

        -- https://maticnetwork.github.io/miden/user_docs/stdlib/math/u64.html
        -- 64 bits integers are emulated by separating the high and low 32 bits.
        translateInstr _ (W.I64Const k) = pure $ noPrefix $ \t ->
          ( [ M.Push k_lo
            , M.Push k_hi
            ]
          , SI64:t
          )
          where FakeW64 k_hi k_lo = toFakeW64 k
        translateInstr _ i@(W.I64Load (W.MemArg offset align)) = case align of
          -- we need to turn [byte_addr, ...] of wasm into
          -- [u32_addr, ...] for masm, and then call mem_load
          -- twice (once at u32_addr, once at u32_addr+1)
          -- to get hi and lo 32 bits of i64 value.
          --
          -- u32_addr = (byte_addr / 4) + (offset / 4) + memBeginning
          3 -> pure $ assumingPrefix i [SI32] $ \t ->
            ( [ M.Push 4, M.IDiv
              , M.Push (fromIntegral offset `div` 4)
              , M.IAdd
              , M.Push memBeginning, M.IAdd -- [addr, ...]
              , M.Dup 0 -- [addr, addr, ...]
              , M.MemLoad Nothing -- [lo, addr, ...]
              , M.Swap 1 -- [addr, lo, ...]
              , M.Push 1, M.IAdd -- [addr+1, lo, ...]
              , M.MemLoad Nothing -- [hi, lo, ...]
              ]
            , SI64:t
            )
          _ -> unsupportedMemAlign align
        translateInstr _ i@(W.I64Store (W.MemArg offset align)) = case align of
          -- we need to turn [val_hi, val_low, byte_addr, ...] of wasm into
          -- [u32_addr, val64_hi, val64_low, ...] for masm,
          -- and the call mem_store twice
          -- (once at u32_addr, once at u32_addr+1)
          -- to get hi and lo 32 bits of i64 value.
          3 -> pure $ assumingPrefix i [SI64, SI32] $ \t ->
            ( [ M.Swap 1, M.Swap 2 -- [byte_addr, hi, lo, ...]
              , M.Push 4, M.IDiv
              , M.Push (fromIntegral offset `div` 4)
              , M.IAdd
              , M.Push memBeginning
              , M.IAdd -- [addr, hi, lo, ...]
              , M.Dup 0 -- [addr, addr, hi, lo, ...]
              , M.Swap 2, M.Swap 1 -- [addr, hi, addr, lo, ...]
              , M.Push 1, M.IAdd -- [addr+1, hi, addr, lo, ...]
              , M.MemStore Nothing -- [hi, addr, lo, ...]
              , M.Drop -- [addr, lo, ...]
              , M.MemStore Nothing -- [lo, ...]
              , M.Drop -- [...]
              ]
            , t
            )
          _ -> unsupportedMemAlign align

        -- turning an i32 into an i64 in wasm corresponds to pushing 0 on the stack.
        -- let's call the i32 'i'. before executing this, the stack looks like [i, ...],
        -- and after like: [0, i, ...].
        -- Since an i64 'x' on the stack is in Miden represented as [x_hi, x_lo], pushing 0
        -- effectively grabs the i32 for the low bits and sets the high 32 bits to 0.
        translateInstr _ i@W.I64ExtendUI32 = pure $
          assumingPrefix i [SI32] $ \t -> ([M.Push 0], SI64:t)
        translateInstr _ i@W.I64Eqz = pure $
          assumingPrefix i [SI64] $ \t -> ([M.IEqz64], SI32:t)
        translateInstr _ W.Drop = pure $ withPrefix $ \ty ->
          -- is the top of the WASM stack an i32 or i64, at this point in time?
          -- i32 => 1 MASM 'drop', i64 => 2 MASM 'drop's.
          case ty of
            SI32 -> return [M.Drop]
            SI64 -> return [M.Drop, M.Drop]

        translateInstr _ i = unsupportedInstruction i

        translateIBinOp :: W.BitSize -> W.IBinOp -> V (StackFun [M.Instruction])
        -- TODO: the u64 module actually provides implementations of many binops for 64 bits
        -- values.
        translateIBinOp W.BS64 op = case op of
          W.IAdd -> pure $ stackBinop op SI64 M.IAdd64
          W.ISub -> pure $ stackBinop op SI64 M.ISub64
          W.IMul -> pure $ stackBinop op SI64 M.IMul64
          _      -> unsupported64Bits op
        translateIBinOp W.BS32 op = case op of
          W.IAdd  -> pure $ stackBinop op SI32 M.IAdd
          W.ISub  -> pure $ stackBinop op SI32 M.ISub 
          W.IMul  -> pure $ stackBinop op SI32 M.IMul
          W.IShl  -> pure $ stackBinop op SI32 M.IShL
          W.IShrU -> pure $ stackBinop op SI32 M.IShR
          W.IAnd  -> pure $ stackBinop op SI32 M.IAnd
          W.IOr   -> pure $ stackBinop op SI32 M.IOr
          W.IXor  -> pure $ stackBinop op SI32 M.IXor
          _       -> unsupportedInstruction (W.IBinOp W.BS32 op)

        translateIRelOp :: W.BitSize -> W.IRelOp -> V (StackFun [M.Instruction])
        translateIRelOp W.BS64 op = case op of
          W.IEq  -> pure $ stackRelop op SI64 M.IEq64
          W.INe  -> pure $ stackRelop op SI64 M.INeq64
          W.ILtU -> pure $ stackRelop op SI64 M.ILt64
          W.IGtU -> pure $ stackRelop op SI64 M.IGt64
          W.ILeU -> pure $ stackRelop op SI64 M.ILte64
          W.IGeU -> pure $ stackRelop op SI64 M.IGte64
          _      -> unsupported64Bits op
        translateIRelOp W.BS32 op = case op of
          W.IEq  -> pure $ stackRelop op SI32 (M.IEq Nothing)
          W.INe  -> pure $ stackRelop op SI32 M.INeq
          W.ILtU -> pure $ stackRelop op SI32 M.ILt
          W.IGtU -> pure $ stackRelop op SI32 M.IGt
          W.ILeU -> pure $ stackRelop op SI32 M.ILte
          W.IGeU -> pure $ stackRelop op SI32 M.IGte
          _      -> unsupportedInstruction (W.IRelOp W.BS32 op)

        -- necessary because of https://github.com/maticnetwork/miden/issues/371
        -- the stack must be left with exactly 16 entries at the end of the program
        -- for proof generaton, so we remove a bunch of entries accordingly.
        stackCleanUp :: [M.Instruction]
        stackCleanUp = [M.TruncateStack]
        -- stackCleanUp n = concat $ replicate n [ M.Swap n', M.Drop ]
        --   where n' = fromIntegral n

concatMapA :: Applicative f => (a -> f [b]) -> [a] -> f [b]
concatMapA f = fmap concat . traverse f

checkTypes :: [W.ValueType] -> V [StackElem]
checkTypes = traverse f
  where f W.I32 = pure SI32
        f W.I64 = pure SI64
        f t     = unsupportedArgType t

stackBinop :: W.IBinOp -> StackElem -> M.Instruction -> StackFun [M.Instruction]
stackBinop op ty xs = assumingPrefix (W.IBinOp sz op) [ty, ty] $ \t -> ([xs], ty:t)
  where sz = if ty == SI32 then W.BS32 else W.BS64
stackRelop :: W.IRelOp -> StackElem -> M.Instruction -> StackFun [M.Instruction]
stackRelop op ty xs = assumingPrefix (W.IRelOp sz op) [ty, ty] $ \t -> ([xs], SI32:t)
  where sz = if ty == SI32 then W.BS32 else W.BS64

{-
  [ W.Instruction ]                                 W.Instruction
V [ StackFun [M.Instruction] ]                   V (t -> ([M.Instruction], t))

we can therefore abort early "enough" to keep the first step applicative, for any
decision that doesn't require the type of the stack.

and with an initial t supplied and a fold applied:
V ([M.Instruction], t)

-}
