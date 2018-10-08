{- |
Module      : What4.Protocol.Online
Copyright   : (c) Galois, Inc 2018
License     : BSD3
Maintainer  : Rob Dockins <rdockins@galois.com>

This module defines an API for interacting with
solvers that support online interaction modes.

-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
module What4.Protocol.Online
  ( OnlineSolver(..)
  , SolverProcess(..)
  , killSolver
  , push
  , pop
  , reset
  , inNewFrame
  , check
  , checkWithAssumptions
  , checkWithAssumptionsAndModel
  , getModel
  , checkAndGetModel
  , getSatResult
  , checkSatisfiable
  , checkSatisfiableWithModel
  ) where

import           Control.Exception
                   ( SomeException(..), bracket_, catch, try, displayException )
import           Data.IORef
import           Control.Monad (void, forM)
import           Data.Text (Text)
import qualified Data.Text.Lazy as LazyText
import           Data.ByteString(ByteString)
import           System.Exit
import           System.IO
import           System.Process
                   (ProcessHandle, interruptProcessGroupOf, waitForProcess)
import qualified System.IO.Streams as Streams

import What4.Expr
import What4.Interface (SolverEvent(..))
import What4.Protocol.SMTWriter
import What4.SatResult
import What4.Utils.HandleReader

-- | This class provides an API for starting and shutting down
--   connections to various different solvers that support
--   online interaction modes.
class SMTReadWriter solver => OnlineSolver scope solver where
  -- | Start a new solver process attached to the given `ExprBuilder`.
  startSolverProcess    :: ExprBuilder scope st fs -> IO (SolverProcess scope solver)
  -- | Shut down a solver process.  The process will be asked to shut down in
  --   a "polite" way, e.g., by sending an `(exit)` message, or by closing
  --   the process's `stdin`.  Use `killProcess` instead to shutdown a process
  --   via a signal.
  shutdownSolverProcess :: SolverProcess scope solver -> IO ()

-- | A live connection to a running solver process.
data SolverProcess scope solver = SolverProcess
  { solverConn  :: !(WriterConn scope solver)
    -- ^ Writer for sending commands to the solver

  , solverHandle :: !ProcessHandle
    -- ^ Handle to the solver process

  , solverStdin :: !Handle
    -- ^ Standard in for the solver process.

  , solverResponse :: !(Streams.InputStream ByteString)
    -- ^ Wrap the solver's stdout, for easier parsing of responses.

  , solverStderr :: !HandleReader
    -- ^ Standard error for the solver process

  , solverEvalFuns :: !(SMTEvalFunctions solver)
    -- ^ The functions used to parse values out of models.

  , solverLogFn :: SolverEvent -> IO ()

  , solverName :: String

  , solverEarlyUnsat :: IORef (Maybe Int)
    -- ^ Some solvers will enter an 'UNSAT' state early, if they can easily
    --   determine that context is unsatisfiable.  If this IORef contains
    --   an integer value, it indicates how many \"pop\" operations need to
    --   be performed to return to a potentially satisfiable state.
    --   A @Just 0@ state indicates the special case that the top-level context
    --   is unsatisfiable, and must be \"reset\".
  }


-- | An impolite way to shut down a solver.  Prefer to use
--   `shutdownSolverProcess`, unless the solver is unresponsive
--   or in some unrecoverable error state.
killSolver :: SolverProcess t solver -> IO ()
killSolver p =
  do catch (interruptProcessGroupOf (solverHandle p)) (\(_ :: SomeException) -> return ())
     void $ waitForProcess (solverHandle p)

-- | Check if the given formula is satisfiable in the current
--   solver state, without requesting a model.
checkSatisfiable ::
  SMTReadWriter solver =>
  SolverProcess scope solver ->
  String ->
  BoolExpr scope ->
  IO (SatResult () ())
checkSatisfiable proc rsn p =
  readIORef (solverEarlyUnsat proc) >>= \case
    Just _  -> return (Unsat ())
    Nothing -> snd <$> checkWithAssumptions proc rsn [p]

-- | Check if the formula is satisifiable in the current
--   solver state.
--   The evaluation funciton can be used to query the model.
--   The model is valid only in the given continuation.
checkSatisfiableWithModel ::
  SMTReadWriter solver =>
  SolverProcess scope solver ->
  String ->
  BoolExpr scope ->
  (SatResult (GroundEvalFn scope) () -> IO a) ->
  IO a
checkSatisfiableWithModel proc rsn p k =
  checkSatisfiable proc rsn p >>= \case
    Sat{}   -> k . Sat =<< getModel proc
    Unsat{} -> k (Unsat ())
    Unknown -> k Unknown

--------------------------------------------------------------------------------
-- Basic solver interaction.

reset :: SMTReadWriter solver => SolverProcess scope solver -> IO ()
reset p =
  do let c = solverConn p
     resetEntryStack c
     writeIORef (solverEarlyUnsat p) Nothing
     addCommand c (resetCommand c)

-- | Push a new solver assumption frame.
push :: SMTReadWriter solver => SolverProcess scope solver -> IO ()
push p =
  readIORef (solverEarlyUnsat p) >>= \case
    Nothing -> do let c = solverConn p
                  pushEntryStack c
                  addCommand c (pushCommand c)
    Just i  -> writeIORef (solverEarlyUnsat p) $! (Just $! i+1)

-- | Pop a previous solver assumption frame.
pop :: SMTReadWriter solver => SolverProcess scope solver -> IO ()
pop p =
  readIORef (solverEarlyUnsat p) >>= \case
    Nothing -> do let c = solverConn p
                  popEntryStack c
                  addCommand c (popCommand c)
    Just i
      | i <= 1 -> do let c = solverConn p
                     popEntryStack c
                     writeIORef (solverEarlyUnsat p) Nothing
                     addCommand c (popCommand c)
      | otherwise -> writeIORef (solverEarlyUnsat p) $! (Just $! i-1)

-- | Perform an action in the scope of a solver assumption frame.
inNewFrame :: SMTReadWriter solver => SolverProcess scope solver -> IO a -> IO a
inNewFrame p m = bracket_ (push p) (pop p) m

checkWithAssumptions ::
  SMTReadWriter solver =>
  SolverProcess scope solver ->
  String ->
  [BoolExpr scope] ->
  IO ([Text], SatResult () ())
checkWithAssumptions proc rsn ps =
  readIORef (solverEarlyUnsat proc) >>= \case
    Just _  -> return ([], Unsat ())
    Nothing ->
      do let c = solverConn proc
         nms <- forM ps (mkAtomicFormula c)
         solverLogFn proc
           SolverStartSATQuery
           { satQuerySolverName = solverName proc
           , satQueryReason = rsn
           }
         addCommandNoAck c (checkWithAssumptionsCommand c nms)
         sat_result <- getSatResult proc
         solverLogFn proc
           SolverEndSATQuery
           { satQueryResult = sat_result
           , satQueryError = Nothing
           }
         return (nms, sat_result)

checkWithAssumptionsAndModel ::
  SMTReadWriter solver =>
  SolverProcess scope solver ->
  String ->
  [BoolExpr scope] ->
  IO (SatResult (GroundEvalFn scope) ())
checkWithAssumptionsAndModel proc rsn ps =
  do (_nms, sat_result) <- checkWithAssumptions proc rsn ps
     case sat_result of
       Unknown -> return Unknown
       Unsat x -> return (Unsat x)
       Sat{} -> Sat <$> getModel proc

-- | Send a check command to the solver, and get the SatResult without asking
--   a model.
check :: SMTReadWriter solver => SolverProcess scope solver -> String -> IO (SatResult () ())
check p rsn =
  readIORef (solverEarlyUnsat p) >>= \case
    Just _  -> return (Unsat ())
    Nothing ->
      do let c = solverConn p
         solverLogFn p
           SolverStartSATQuery
           { satQuerySolverName = solverName p
           , satQueryReason = rsn
           }
         addCommandNoAck c (checkCommand c)
         sat_result <- getSatResult p
         solverLogFn p
           SolverEndSATQuery
           { satQueryResult = sat_result
           , satQueryError = Nothing
           }
         return sat_result

-- | Send a check command to the solver and get the model in the case of a SAT result.
--
-- This may fail if the solver terminates.
checkAndGetModel :: SMTReadWriter solver => SolverProcess scope solver -> String -> IO (SatResult (GroundEvalFn scope) ())
checkAndGetModel yp rsn = do
  sat_result <- check yp rsn
  case sat_result of
    Unsat x -> return $! Unsat x
    Unknown -> return $! Unknown
    Sat () -> Sat <$> getModel yp

-- | Following a successful check-sat command, build a ground evaulation function
--   that will evaluate terms in the context of the current model.
getModel :: SMTReadWriter solver => SolverProcess scope solver -> IO (GroundEvalFn scope)
getModel p = smtExprGroundEvalFn (solverConn p)
             $ smtEvalFuns (solverConn p) (solverResponse p)


-- | Get the sat result from a previous SAT command.
getSatResult :: SMTReadWriter s => SolverProcess t s -> IO (SatResult () ())
getSatResult yp = do
  let ph = solverHandle yp
  let err_reader = solverStderr yp
  sat_result <- try (smtSatResult yp (solverResponse yp))
  case sat_result of
    Right ok -> return ok

    Left (SomeException e) ->
       do txt <- readAllLines err_reader
          -- Interrupt process; suppress any exceptions that occur.
          catch (interruptProcessGroupOf ph) (\(_ :: IOError) -> return ())
          -- Wait for process to end
          ec <- waitForProcess ph
          let ec_code = case ec of
                          ExitSuccess -> 0
                          ExitFailure code -> code
          fail $ unlines
                  [ "The solver terminated with exit code "++
                                              show ec_code ++ ".\n"
                  , "*** exception: " ++ displayException e
                  , "*** standard error:"
                  , LazyText.unpack txt
                  ]
