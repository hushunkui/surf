-------------------------------------------------------------------------------
-- Title      : PGP3 Support Package
-------------------------------------------------------------------------------
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2017-03-30
-- Platform   : 
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description: 
-------------------------------------------------------------------------------
-- This file is part of <PROJECT_NAME>. It is subject to
-- the license terms in the LICENSE.txt file found in the top-level directory
-- of this distribution and at:
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
-- No part of <PROJECT_NAME>, including this file, may be
-- copied, modified, propagated, or distributed except according to the terms
-- contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;
use work.SsiPkg.all;

package Pgp3Pkg is

   constant PGP3_VERSION_C : slv(2 downto 0) := "011";

   constant PGP3_AXIS_CONFIG_C : AxiStreamConfigType :=
      ssiAxiStreamConfig(
         dataBytes => 8,
         tKeepMode => TKEEP_COMP_C,
         tUserMode => TUSER_FIRST_LAST_C,
         tDestBits => 4,
         tUserBits => 2);

   -- Define K code BTFs
   constant IDLE_C : slv(7 downto 0)   := X"99";
   constant SOF_C  : slv(7 downto 0)   := X"AA";
   constant EOF_C  : slv(7 downto 0)   := X"55";
   constant SOC_C  : slv(7 downto 0)   := X"CC";
   constant EOC_C  : slv(7 downto 0)   := X"33";
   constant SKP_C  : slv(7 downto 0)   := X"66";
   constant USER_C : Slv8Array(0 to 7) := (X"78", X"87", X"2D", X"D2", X"1E", X"E1", X"B4", X"4B");

   constant D_HEADER_C : slv(1 downto 0) := "01";
   constant K_HEADER_C : slv(1 downto 0) := "10";

   constant SCRAMBLER_TAPS_C : IntegerArray(0 to 1) := (0 => 39, 1 => 58);

   type Pgp3TxInType is record
      opCodeEn     : sl;
      opCodeNumber : slv(2 downto 0);
      opCodeData   : slv(55 downto 0);
   end record Pgp3TxInType;

   type Pgp3TxOutType is record
      locOverflow : slv(15 downto 0);
      locPause    : slv(15 downto 0);
      phyTxReady  : sl;
      linkReady   : sl;
      frameTx     : sl;                 -- A good frame was transmitted
      frameTxErr  : sl;                 -- An errored frame was transmitted
   end record;

   type Pgp3RxInType is record
      loopback : slv(2 downto 0);
   end record Pgp3RxInType;

   type Pgp3RxOutType is record
      phyRxReady     : sl;
      linkReady      : sl;                -- locRxLinkReady
      frameRx        : sl;                -- A good frame was received
      frameRxErr     : sl;                -- An errored frame was received
      cellError      : sl;                -- A cell error has occured
      opCodeEn       : sl;                -- Opcode valid
      opCodeNumber   : slv(2 downto 0);   -- Opcode number
      opCodeData     : slv(55 downto 0);  -- Opcode data
      remRxLinkReady : sl;                -- Far end RX has link
      remRxOverflow  : slv(15 downto 0);  -- Far end RX overflow status
      remRxPause     : slv(15 downto 0);  -- Far end pause status
   end record Pgp3RxOutType;

   function makeLinkInfo (
      locRxFifoCtrl  : AxiStreamCtrlArray;
      locRxLinkReady : sl)
      return slv;

   procedure extractLinkInfo (
      linkInfo       : in    slv(39 downto 0);
      remRxFifoCtrl  : inout AxiStreamCtrlArray;
      remRxLinkReady : inout sl;
      version        : inout slv(2 downto 0));

end package Pgp3Pkg;

package body Pgp3Pkg is

   function makeLinkInfo (
      locRxFifoCtrl  : AxiStreamCtrlArray;
      locRxLinkReady : sl)
      return slv
   is
      variable ret : slv(39 downto 0) := (others => '0');
   begin
      for i in locRxFifoCtrl'range loop
         ret(i)    := locRxFifoCtrl(i).pause;
         ret(i+16) := locRxFifoCtrl(i).overflow;
      end loop;
      ret(32)           := locRxLinkReady;
      ret(35 downto 33) := PGP3_VERSION_C;
      return ret;
   end function makeLinkInfo;

   procedure extractLinkInfo (
      linkInfo       : in    slv(39 downto 0);
      remRxFifoCtrl  : inout AxiStreamCtrlArray;
      remRxLinkReady : inout sl;
      version        : inout slv(2 downto 0)) is
   begin
      for i in remRxFifoCtrl'range loop
         remRxFifoCtrl(i).pause    := linkInfo(i);
         remRxFifoCtrl(i).overflow := linkInfo(i+16);
      end loop;
      remRxLinkReady := linkInfo(32);
      version        := linkInfo(35 downto 33);
   end procedure extractLinkInfo;

end package body Pgp3Pkg;
