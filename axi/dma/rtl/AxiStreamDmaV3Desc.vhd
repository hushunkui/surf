-------------------------------------------------------------------------------
-- File       : AxiStreamDmaV3Desc.vhd
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2018-06-29
-- Last update: 2018-07-05
-------------------------------------------------------------------------------
-- Description:
-- Descriptor manager for AXI DMA read and write engines.
-------------------------------------------------------------------------------
-- This file is part of 'SLAC Firmware Standard Library'.
-- It is subject to the license terms in the LICENSE.txt file found in the
-- top-level directory of this distribution and at:
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
-- No part of 'SLAC Firmware Standard Library', including this file,
-- may be copied, modified, propagated, or distributed except according to
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;
use ieee.NUMERIC_STD.all;

use work.StdRtlPkg.all;
use work.AxiPkg.all;
use work.AxiLitePkg.all;
use work.AxiDmaPkg.all;
use work.ArbiterPkg.all;
use work.AxiPciePkg.all;

entity AxiStreamDmaV3Desc is
   generic (
      TPD_G             : time                  := 1 ns;             -- Propagation Delay
      CHAN_COUNT_G      : integer range 1 to 16 := 1;                -- Channel count
      AXIL_BASE_ADDR_G  : slv(31 downto 0)      := x"00000000";      -- Axi Lite Base Address
      AXI_READY_EN_G    : boolean               := false;            -- Axi ready signal
      AXI_CONFIG_G      : AxiConfigType         := AXI_CONFIG_INIT_C;
      DESC_AWIDTH_G     : integer range 4 to 12 := 12;               -- Descriptor Address width
      DESC_ARB_G        : boolean               := true;
      DESC_VERSION_G    : integer range 1 to 2  := 1;                -- If descriptor version is 1, descriptor size is 64 bits
                                                                     -- else 128 bits if the version is 2
      ACK_WAIT_BVALID_G : boolean               := true);           -- Wait ack valid
   port(
      -- Clock/Reset
      axiClk          : in  sl;
      axiRst          : in  sl;
      -- Local AXI Lite Bus
      axilReadMaster  : in  AxiLiteReadMasterType;
      axilReadSlave   : out AxiLiteReadSlaveType;
      axilWriteMaster : in  AxiLiteWriteMasterType;
      axilWriteSlave  : out AxiLiteWriteSlaveType;
      -- Additional signals
      interrupt       : out sl;
      online          : out slv (CHAN_COUNT_G-1 downto 0);
      acknowledge     : out slv (CHAN_COUNT_G-1 downto 0);
      -- DMA write descriptor request, ack and return
      dmaWrDescReq    : in  AxiWriteDmaDescReqArray(CHAN_COUNT_G-1 downto 0);
      dmaWrDescAck    : out AxiWriteDmaDescAckArray(CHAN_COUNT_G-1 downto 0);
      dmaWrDescRet    : in  AxiWriteDmaDescRetArray(CHAN_COUNT_G-1 downto 0);
      dmaWrDescRetAck : out slv(CHAN_COUNT_G-1 downto 0);
      -- DMA read descriptor request, ack and return
      dmaRdDescReq    : out AxiReadDmaDescReqArray
      dmaRdDescAck    : in  slv(CHAN_COUNT_G-1 downto 0);
      dmaRdDescRet    : in  AxiReadDmaDescRetArray(CHAN_COUNT_G-1 downto 0);
      dmaRdDescRetAck : out slv(CHAN_COUNT_G-1 downto 0);
      -- Config
      axiRdCache      : out slv(3 downto 0);
      axiWrCache      : out slv(3 downto 0);
      -- AXI Interface
      axiWriteMaster  : out AxiWriteMasterType;
      axiWriteSlave   : in  AxiWriteSlaveType;
      axiWriteCtrl    : in  AxiCtrlType := AXI_CTRL_UNUSED_C);
end AxiStreamDmaV3Desc;

architecture rtl of AxiStreamDmaV3Desc is

   constant CROSSBAR_CONN_C : slv(15 downto 0) := x"FFFF";                                      -- 16 bit Crossbar connection

   constant CB_COUNT_C : integer := 2;                                                          -- Crossbar count = 2

   constant LOC_INDEX_C       : natural            := 0;                                        -- Local index
   constant LOC_BASE_ADDR_C   : slv(31 downto 0)   := AXIL_BASE_ADDR_G(31 downto 16) & x"0000"; -- Local Base Address
   constant LOC_NUM_BITS_C    : natural            := 14;                                       -- Local number of bits

   constant ADDR_INDEX_C      : natural            := 0;                                        -- Address index
   constant ADDR_BASE_ADDR_C  : slv(31 downto 0)   := AXIL_BASE_ADDR_G(31 downto 16) & x"4000"; -- Base address
   constant ADDR_NUM_BITS_C   : natural            := 14;                                       -- Number of bits

   -- Crossbar Master configuration
   constant AXI_CROSSBAR_MASTERS_CONFIG_C : AxiLiteCrossbarMasterConfigArray(CB_COUNT_C-1 downto 0) := (
      LOC_INDEX_C       => (
         baseAddr       => LOC_BASE_ADDR_C,
         addrBits       => LOC_NUM_BITS_C,
         connectivity   => CROSSBAR_CONN_C),
      ADDR_INDEX_C      => (
         baseAddr       => ADDR_BASE_ADDR_C,
         addrBits       => ADDR_NUM_BITS_C,
         connectivity   => CROSSBAR_CONN_C));

   signal intReadMasters   : AxiLiteReadMasterArray(CB_COUNT_C-1 downto 0);   -- 2 bit Read master Signal
   signal intReadSlaves    : AxiLiteReadSlaveArray(CB_COUNT_C-1 downto 0);    -- 2 bit Read slave signal
   signal intWriteMasters  : AxiLiteWriteMasterArray(CB_COUNT_C-1 downto 0);  -- 2 bit Write master signal
   signal intWriteSlaves   : AxiLiteWriteSlaveArray(CB_COUNT_C-1 downto 0);   -- 2 bit Write slave signal

   type DescStateType is (IDLE_S, WRITE_S, READ_S, WAIT_S); -- Descriptor state type

   constant CHAN_SIZE_C    : integer := bitSize(CHAN_COUNT_G-1);  -- Descriptor channel size = 1 (bitsize (0) returns 1)
   constant DESC_COUNT_C   : integer := CHAN_COUNT_G*2;           -- Descriptor count = 1*2 = 2
   constant DESC_SIZE_C    : integer := bitSize(DESC_COUNT_C-1);  -- Descriptor Size  = bitSize(2-1) = bitSize(1) = 1

   -- Register Type
   type RegType is record

      -- Write descriptor interface
      dmaWrDescAck    : AxiWriteDmaDescAckArray(CHAN_COUNT_G-1 downto 0); -- DMA write descriptor ack (1 bit)
      dmaWrDescRetAck : slv(CHAN_COUNT_G-1 downto 0);                     -- DMA write descriptor return ack (1 bit)

      -- Read descriptor interface
      dmaRdDescReq    : AxiReadDmaDescReqArray(CHAN_COUNT_G-1 downto 0);  -- DMA read descriptor request (1 bit)
      dmaRdDescRetAck : slv(CHAN_COUNT_G-1 downto 0);                     -- DMA read descriptor return ack (1 bit)

      -- Axi-Lite
      axilReadSlave  : AxiLiteReadSlaveType;  -- Axi-Lite Read Slave
      axilWriteSlave : AxiLiteWriteSlaveType; -- Axi-Lite Write Slave

      -- AXI
      axiWriteMaster : AxiWriteMasterType;    -- Axi Write Master

      -- Configuration
      buffBaseAddr : slv(63 downto 32);            -- For buffer entries - 32 bit buffer base address
      wrBaseAddr   : slv(63 downto 0);             -- For write ring buffer - 64 bit write base address
      rdBaseAddr   : slv(63 downto 0);             -- For read ring buffer - 64 bit read base address
      maxSize      : slv(23 downto 0);             -- 24 bit Max buffer size
      contEn       : sl;                           -- Container enable?
      dropEn       : sl;
      enable       : sl;
      intEnable    : sl;
      online       : slv(CHAN_COUNT_G-1 downto 0); -- buffer online (1 bit)
      acknowledge  : slv(CHAN_COUNT_G-1 downto 0); -- buffer acknowledge (1 bit)
      fifoReset    : sl;                           -- FIFO reset
      intSwAckReq  : sl;                           --
      intAckCount  : slv(31 downto 0);             -- Ack count (32 bits)
      descWrCache  : slv(3 downto 0);              -- Descriptor write cache (4 bits)
      buffRdCache  : slv(3 downto 0);              -- Buffer read cache (4 bits)
      buffWrCache  : slv(3 downto 0);              -- Buffer write cache (4 bits)

      -- FIFOs
      fifoDin        : slv(31 downto 0); -- 32 bit input FIFO
      wrFifoWr       : sl;               -- write-write FIFO
      rdFifoWr       : slv(1 downto 0);  -- read-write FIFO
      addrFifoSel    : sl;               -- Fifo address select?
      wrFifoRd       : sl;               -- write-read FIFO
      wrFifoValiDly  : slv(1 downto 0);  -- Write FIFO valid
      wrAddr         : slv(31 downto 0); -- Write address (32 bits)
      wrAddrValid    : sl;               -- Write address valid
      rdFifoRd       : sl;               -- Read-read FIFO
      rdFifoValiDly  : slv(1 downto 0);  -- Read FIFO valid
      rdAddr         : slv(31 downto 0); -- Read Address
      rdAddrValid    : sl;               -- Read address valid

      -- Write Desc Request
      wrReqValid  : sl;                                -- Write request valid
      wrReqCnt    : natural range 0 to CHAN_COUNT_G-1; -- Write request count
      wrReqNum    : slv(CHAN_SIZE_C-1 downto 0);       -- Write request number
      wrReqAcks   : slv(CHAN_COUNT_G-1 downto 0);      -- Write request acks
      wrReqMissed : slv(31 downto 0);                  -- Write Request missed

      -- Desc Return
      descRetList : slv(DESC_COUNT_C-1 downto 0);      -- Descriptor return list [1:0]
      descState   : DescStateType;                     -- Descriptor state
      descRetCnt  : natural range 0 to DESC_COUNT_C-1; -- Descriptor return count
      descRetNum  : slv(DESC_SIZE_C-1 downto 0);       -- Descriptor return number
      descRetAcks : slv(DESC_COUNT_C-1 downto 0);      -- Descriptor return acks
      wrIndex     : slv(DESC_AWIDTH_G-1 downto 0);     -- write index
      wrMemAddr   : slv(63 downto 0);                  -- write memory address
      rdIndex     : slv(DESC_AWIDTH_G-1 downto 0);     -- read index
      rdMemAddr   : slv(63 downto 0);                  -- read memory address
      intReqEn    : sl;                                -- Request enable?
      intReqCount : slv(31 downto 0);                  -- Request count
      interrupt   : sl;

   end record RegType;

   -- Initialize all registers
   constant REG_INIT_C : RegType := (
      dmaWrDescAck    => (others => AXI_WRITE_DMA_DESC_ACK_INIT_C), -- Set the dma write descriptor ack to the Axi variable
      dmaWrDescRetAck => (others => '0'),                           -- Set the elements in the dma write descriptor ack to 0
      dmaRdDescReq    => (others => AXI_READ_DMA_DESC_REQ_INIT_C),  -- Set the dma read descriptor request to the axi variable
      dmaRdDescRetAck => (others => '0'),                           -- Set the elements in the dma read descriptor to 0
      axilReadSlave   => AXI_LITE_READ_SLAVE_INIT_C,                -- Set it to the Axi lite read variable
      axilWriteSlave  => AXI_LITE_WRITE_SLAVE_INIT_C,               -- Set it to the Axi lite write variable
      axiWriteMaster  => axiWriteMasterInit(AXI_CONFIG_G, '1', "01", "0000"), -- bready = 1, AXI_BURST_C = 01, AXI_CACHE_C = 1111.
      buffBaseAddr    => (others => '0'),                           -- buffer base address initialized to 0
      wrBaseAddr      => (others => '0'),                           -- buffer write base address initialized to 0
      rdBaseAddr      => (others => '0'),                           -- buffer read base address initialized to 0
      maxSize         => (others => '0'),                           -- buffer max size initialized to 0
      contEn          => '0',                                       -- container enable?
      intEnable       => '0',
      online          => (others => '0'),
      acknowledge     => (others => '0'),
      fifoReset       => '1',
      intSwAckReq     => '0',
      intAckCount     => (others => '0'),
      descWrCache     => (others => '0'),
      buffRdCache     => (others => '0'),
      buffWrCache     => (others => '0'),
      fifoDin         => (others => '0'),
      wrFifoWr        => '0',
      rdFifoWr        => (others => '0'),
      addrFifoSel     => '0',
      wrFifoRd        => '0',
      wrFifoValidDly  => (others => '0'),
      wrAddr          => (others => '0'),
      wrAddrValid     => '0',
      rdFifoRd        => '0',
      rdFifoValidDly  => (others => '0'),
      rdAddr          => (others => '0'),
      rdAddrValid     => '0',
      wrReqValid      => '0',
      wrReqCnt        => 0,
      wrReqNum        => (others => '0'),
      wrReqAcks       => (others => '0'),
      wrReqMissed     => (others => '0'),
      descRetList     => (others => '0'),
      descState       => IDLE_S,
      descRetCnt      => 0,
      descRetNum      => (others => '0'),
      descRetAcks     => (others => '0'),
      wrIndex         => (others => '0'),
      wrMemAddr       => (others => '0'),
      rdIndex         => (others => '0'),
      rdMemAddr       => (others => '0'),
      intReqEn        => '0',
      intReqCount     => (others => '0'),
      interrupt       => '0'
      );

   signal r            : RegType := REG_INIT_C;         -- RegType signal which contains all the intialized variables.
   signal rin          : RegType;                       -- RegType rin signal
   signal pause        : sl;
   signal rdFifoValid  : slv(1 downto 0);               -- Read Fifo valid
   signal rdFifoDout   : slv(63 downto 0);              -- Read Fifo output
   signal wrFifoValid  : sl;                            -- Write Fifo Valid
   signal wrFifoDout   : slv(15 downto 0);              -- Write Fifo output
   signal addrRamDout  : slv(31 downto 0);              -- Ram address output
   signal addrRamAddr  : slv(DESC_AWIDTH_G-1 downto 0); -- Ram address - 12 bits
   signal intSwAckEn   : sl;
   signal intCompValid : sl;
   signal intDiffValid : sl;
   signal invalidCount : sl;
   signal diffCnt      : slv(31 downto 0);

   -- attribute dont_touch                 : string;
   -- attribute dont_touch of r            : signal is "true";
   -- attribute dont_touch of intSwAckEn   : signal is "true";
   -- attribute dont_touch of invalidCount : signal is "true";
   -- attribute dont_touch of diffCnt      : signal is "true";
begin
   -----------------------------------------
   -- Axi Descriptor Dma Config
   -----------------------------------------
--   U_AxiDescDmaConfig : entity work.DMA_AXI_CONFIG_C
--      generic map(
--         ADDR_WIDTH_C   => DESC_AWIDTH_G,
--         DATA_BYTES_C   => 16,
--         ID_BITS_C      => 5,
--         LEN_BITS_C     => 8);

   -----------------------------------------
   -- Crossbar
   -----------------------------------------
   U_AxiCrossbar : entity work.AxiLiteCrossbar
      generic map (
         TPD_G              => TPD_G,
         NUM_SLAVE_SLOTS_G  => 1,
         NUM_MASTER_SLOTS_G => CB_COUNT_C, --CB_COUNT_C = 2
         DEC_ERROR_RESP_G   => AXI_RESP_OK_C,
         MASTERS_CONFIG_G   => AXI_CROSSBAR_MASTERS_CONFIG_C)
      port map (
         axiClk              => axiClk,
         axiClkRst           => axiRst,
         sAxiWriteMasters(0) => axilWriteMaster,
         sAxiWriteSlaves(0)  => axilWriteSlave,
         sAxiReadMasters(0)  => axilReadMaster,
         sAxiReadSlaves(0)   => axilReadSlave,
         mAxiWriteMasters    => intWriteMasters,
         mAxiWriteSlaves     => intWriteSlaves,
         mAxiReadMasters     => intReadMasters,
         mAxiReadSlaves      => intReadSlaves);

   -----------------------------------------
   -- Write Free List FIFO
   -----------------------------------------
   U_DescFifo : entity work.Fifo
      generic map (
         TPD_G           => TPD_G,
         GEN_SYNC_FIFO_G => true,
         FWFT_EN_G       => true,
         DATA_WIDTH_G    => 16,
         ADDR_WIDTH_G    => DESC_AWIDTH_G)
      port map (
         rst    => r.fifoReset,
         wr_clk => axiClk,
         wr_en  => r.wrFifoWr,
         din    => r.fifoDin(15 downto 0),
         rd_clk => axiClk,
         rd_en  => r.wrFifoRd,
         dout   => wrFifoDout,
         valid  => wrFifoValid);

   -----------------------------------------
   -- Read Transaction FIFOs
   -----------------------------------------
   U_RdLowFifo : entity work.Fifo
      generic map (
         TPD_G           => TPD_G,
         GEN_SYNC_FIFO_G => true,
         FWFT_EN_G       => true,
         DATA_WIDTH_G    => 32,
         ADDR_WIDTH_G    => DESC_AWIDTH_G)
      port map (
         rst    => r.fifoReset,
         wr_clk => axiClk,
         wr_en  => r.rdFifoWr(0),
         din    => r.fifoDin,
         rd_clk => axiClk,
         rd_en  => r.rdFifoRd,
         dout   => rdFifoDout(31 downto 0),
         valid  => rdFifoValid(0));

   U_RdHighFifo : entity work.Fifo
      generic map (
         TPD_G           => TPD_G,
         GEN_SYNC_FIFO_G => true,
         FWFT_EN_G       => true,
         DATA_WIDTH_G    => 32,
         ADDR_WIDTH_G    => DESC_AWIDTH_G)
      port map (
         rst    => r.fifoReset,
         wr_clk => axiClk,
         wr_en  => r.rdFifoWr(1),
         din    => r.fifoDin,
         rd_clk => axiClk,
         rd_en  => r.rdFifoRd,
         dout   => rdFifoDout(63 downto 32),
         valid  => rdFifoValid(1));

   -----------------------------------------
   -- Address RAM
   -----------------------------------------
   U_AddrRam : entity work.AxiDualPortRam
      generic map (
         TPD_G        => TPD_G,
         REG_EN_G     => true,
         BRAM_EN_G    => true,
         COMMON_CLK_G => true,
         ADDR_WIDTH_G => DESC_AWIDTH_G,
         DATA_WIDTH_G => 32)
      port map (
         axiClk         => axiClk,
         axiRst         => axiRst,
         axiReadMaster  => intReadMasters(ADDR_INDEX_C),
         axiReadSlave   => intReadSlaves(ADDR_INDEX_C),
         axiWriteMaster => intWriteMasters(ADDR_INDEX_C),
         axiWriteSlave  => intWriteSlaves(ADDR_INDEX_C),
         clk            => axiClk,
         rst            => axiRst,
         addr           => addrRamAddr,
         dout           => addrRamDout);

   addrRamAddr <= wrFifoDout(DESC_AWIDTH_G-1 downto 0) when r.addrFifoSel = '0' else
                  rdFifoDout(DESC_AWIDTH_G+3 downto 4);

   -- Check for invalid count
   U_DspComparator : entity work.DspComparator
      generic map (
         TPD_G   => TPD_G,
         WIDTH_G => 32)
      port map (
         clk     => axiClk,
         ibValid => r.intSwAckReq,
         ain     => r.intReqCount,
         bin     => r.intAckCount,
         obValid => intCompValid,
         ls      => invalidCount);  --  (a <  b) <--> r.intAckCount > r.intReqCount

   U_DspSub : entity work.DspAddSub
      generic map (
         TPD_G   => TPD_G,
         WIDTH_G => 32)
      port map (
         clk     => axiClk,
         ibValid => r.intSwAckReq,
         ain     => r.intReqCount,
         bin     => r.intAckCount,
         add     => '0',                -- '0' = subtract
         obValid => intDiffValid,       -- sync'd up with U_DspComparator
         pOut    => diffCnt);  -- a - b <--> r.intReqCount - r.intAckCount

   -- Both DSPs are done
   intSwAckEn <= intDiffValid and intCompValid;

   -----------------------------------------
   -- Control Logic
   -----------------------------------------

   -- Choose pause source
   pause <= '0' when (AXI_READY_EN_G) else axiWriteCtrl.pause;

   comb : process (addrRamDout, axiRst, axiWriteSlave, diffCnt, dmaRdDescAck,
                   dmaRdDescRet, dmaWrDescReq, dmaWrDescRet, intSwAckEn,
                   intReadMasters, intWriteMasters, invalidCount, pause, r,
                   rdFifoDout, rdFifoValid, wrFifoDout, wrFifoValid) is

      variable v            : RegType;
      variable wrReqList    : slv(CHAN_COUNT_G-1 downto 0);
      --variable descRetList  : slv(DESC_COUNT_C-1 downto 0);
      variable descRetValid : sl;
      variable descIndex    : natural;
      variable dmaRdReq     : AxiReadDmaDescReqType;
      variable rdIndex      : natural;
      variable regCon       : AxiLiteEndPointType;
   begin

      -- Latch the current value
      v := r;

      -- Clear one shot signals
      v.rdFifoWr    := "00";
      v.rdFifoRd    := '0';
      v.wrFifoWr    := '0';
      v.wrFifoRd    := '0';
      v.acknowledge := (others => '0');

      -----------------------------
      -- Register access
      -----------------------------
      -- Assigning addresses?

      -- Start transaction block
      axiSlaveWaitTxn(regCon, intWriteMasters(LOC_INDEX_C), intReadMasters(LOC_INDEX_C), v.axilWriteSlave, v.axilReadSlave);

      axiSlaveRegister(regCon, x"000", 0, v.enable);
      axiSlaveRegisterR(regCon, x"000", 24, toSlv(2, 8));  -- Version 2 = 2, Version1 = 0

      axiSlaveRegister(regCon, x"004", 0, v.intEnable);
      axiSlaveRegister(regCon, x"008", 0, v.contEn);
      axiSlaveRegister(regCon, x"00C", 0, v.dropEn);
      axiSlaveRegister(regCon, x"010", 0, v.wrBaseAddr(31 downto 0));
      axiSlaveRegister(regCon, x"014", 0, v.wrBaseAddr(63 downto 32));
      axiSlaveRegister(regCon, x"018", 0, v.rdBaseAddr(31 downto 0));
      axiSlaveRegister(regCon, x"01C", 0, v.rdBaseAddr(63 downto 32));
      axiSlaveRegister(regCon, x"020", 0, v.fifoReset);
      axiSlaveRegister(regCon, x"024", 0, v.buffBaseAddr(63 downto 32));
      axiSlaveRegister(regCon, x"028", 0, v.maxSize);
      axiSlaveRegister(regCon, x"02C", 0, v.online);
      axiSlaveRegister(regCon, x"030", 0, v.acknowledge);

      axiSlaveRegisterR(regCon, x"034", 0, toSlv(CHAN_COUNT_G, 8));
      axiSlaveRegisterR(regCon, x"038", 0, toSlv(DESC_AWIDTH_G, 8));
      axiSlaveRegister(regCon, x"03C",  0, v.descWrCache);
      axiSlaveRegister(regCon, x"03C",  8, v.buffWrCache);
      axiSlaveRegister(regCon, x"03C", 12, v.buffRdCache);

      axiSlaveRegister(regCon, x"040", 0, v.fifoDin);
      axiWrDetect(regCon, x"040", v.rdFifoWr(0));

      axiSlaveRegister(regCon, x"044", 0, v.fifoDin);
      axiWrDetect(regCon, x"044", v.rdFifoWr(1));

      axiSlaveRegister(regCon, x"048", 0, v.fifoDin);
      axiWrDetect(regCon, x"048", v.wrFifoWr);

      axiSlaveRegister(regCon, x"04C", 0, v.intAckCount(15 downto 0));
      axiSlaveRegister(regCon, x"04C", 17, v.intEnable);
      axiWrDetect(regCon, x"04C", v.intSwAckReq);

      axiSlaveRegisterR(regCon, x"050", 0, r.intReqCount);
      axiSlaveRegisterR(regCon, x"054", 0, r.wrIndex);
      axiSlaveRegisterR(regCon, x"058", 0, r.rdIndex);

      axiSlaveRegisterR(regCon, x"05C", 0, r.wrReqMissed);

      -- End transaction block
      axiSlaveDefault(regCon, v.axilWriteSlave, v.axilReadSlave, AXI_RESP_DECERR_C);

      --------------------------------------
      -- Address FIFO Control
      --------------------------------------
      -- Alternate between read and write FIFOs to common address pool
      v.addrFifoSel := not(r.addrFifoSel);

      -- Write pipeline
      if r.wrFifoRd = '1' then
         v.wrFifoValidDly := (others => '0');
         v.wrAddr         := (others => '1');
         v.wrAddrValid    := '0';
      else
         v.wrFifoValidDly := (wrFifoValid and (not r.addrFifoSel)) & r.wrFifoValidDly(1);
         if r.wrFifoValidDly(0) = '1' then
            v.wrAddr      := addrRamDout;
            v.wrAddrValid := '1';
         end if;
      end if;

      -- Read pipeline
      if r.rdFifoRd = '1' then
         v.rdFifoValidDly := (others => '0');
         v.rdAddr         := (others => '1');
         v.rdAddrValid    := '0';
      else
         v.rdFifoValidDly := (rdFifoValid(0) and rdFifoValid(1) and r.addrFifoSel) & r.rdFifoValidDly(1);
         if r.rdFifoValidDly(0) = '1' then
            v.rdAddr      := addrRamDout;
            v.rdAddrValid := '1';
         end if;
      end if;

      --------------------------------------
      -- Write Descriptor Requests
      --------------------------------------

      -- Clear acks
      for i in 0 to CHAN_COUNT_G-1 loop
         v.dmaWrDescAck(i).valid := '0';
      end loop;

      -- Arbitrate
      if r.wrReqValid = '0' then

         -- Format requests
         wrReqList := (others => '0');
         for i in 0 to CHAN_COUNT_G-1 loop
            wrReqList(i) := dmaWrDescReq(i).valid;
         end loop;

         -- Arbitrate between requesters
         if r.enable = '1' and r.wrFifoRd = '0' and r.wrAddrValid = '1' then
            if (DESC_ARB_G = true) then
               arbitrate(wrReqList, r.wrReqNum, v.wrReqNum, v.wrReqValid, v.wrReqAcks);
            else
               -- Check the counter
               if (r.wrReqCnt = (CHAN_COUNT_G-1)) then
                  -- Reset the counter
                  v.wrReqCnt := 0;
               else
                  -- Increment the counter
                  v.wrReqCnt := r.wrReqCnt + 1;
               end if;
               -- Check for valid 
               if (wrReqList(r.wrReqCnt) = '1') then
                  v.wrReqValid := '1';
                  v.wrReqNum   := toSlv(r.wrReqCnt, CHAN_SIZE_C);
               else
                  v.wrReqValid := '0';
               end if;
            end if;
         end if;

         if r.enable = '0' then
            v.wrReqMissed := (others => '0');
         elsif wrReqList /= 0 and wrFifoValid = '0' then
            v.wrReqMissed := r.wrReqMissed + 1;
         end if;

      -- Valid arbitration result
      else
         for i in 0 to CHAN_COUNT_G-1 loop
            v.dmaWrDescAck(i).address              := r.buffBaseAddr & r.wrAddr;
            v.dmaWrDescAck(i).dropEn               := r.dropEn;
            v.dmaWrDescAck(i).contEn               := r.contEn;
            v.dmaWrDescAck(i).buffId(11 downto 0)  := wrFifoDout(11 downto 0);
            v.dmaWrDescAck(i).maxSize(23 downto 0) := r.maxSize;
         end loop;

         v.dmaWrDescAck(conv_integer(r.wrReqNum)).valid := '1';
         v.wrFifoRd                                     := '1';
         v.wrReqValid                                   := '0';

      end if;


      --------------------------------------
      -- Read/Write Descriptor Returns
      --------------------------------------

      -- Clear acks
      v.dmaWrDescRetAck := (others => '0');
      v.dmaRdDescRetAck := (others => '0');

      -- Axi Cache
      v.axiWriteMaster.awcache := r.descWrCache;

      -- Reset strobing Signals
      if (axiWriteSlave.awready = '1') or (AXI_READY_EN_G = false) then
         v.axiWriteMaster.awvalid := '0';
      end if;
      if (axiWriteSlave.wready = '1') or (AXI_READY_EN_G = false) then
         v.axiWriteMaster.wvalid := '0';
         v.axiWriteMaster.wlast  := '0';
      end if;

      -- Generate descriptor ring addresses
      v.wrMemAddr := r.wrBaseAddr + (r.wrIndex & "000");
      v.rdMemAddr := r.rdBaseAddr + (r.rdIndex & "000");

      -- State machine
      case r.descState is
         ----------------------------------------------------------------------
         when IDLE_S =>

            -- Format requests
            v.descRetList := (others => '0');                  -- Descriptor Return List set to 0
            for i in 0 to CHAN_COUNT_G-1 loop                  -- CHAN_COUNT_G = 1
               v.descRetList(i*2)   := dmaWrDescRet(i).valid;  -- i = 0, i = 2
               v.descRetList(i*2+1) := dmaRdDescRet(i).valid;  -- i = 1, i = 3
            end loop;

            -- Arbitrate between requesters
            if r.enable = '1' and pause = '0' then
               if (DESC_ARB_G = true) then
                  arbitrate(v.descRetList, r.descRetNum, v.descRetNum, descRetValid, v.descRetAcks);
               else
                  -- Check the counter
                  if (r.descRetCnt = (DESC_COUNT_C-1)) then
                     -- Reset the counter
                     v.descRetCnt := 0;
                  else
                     -- Increment the counter
                     v.descRetCnt := r.descRetCnt + 1;
                  end if;
                  -- Check for valid 
                  if (v.descRetList(r.descRetCnt) = '1') then
                     descRetValid := '1';
                     v.descRetNum := toSlv(r.descRetCnt, DESC_SIZE_C);
                  else
                     descRetValid := '0';
                  end if;
               end if;

               -- Valid request
               if descRetValid = '1' then
                  if v.descRetNum(0) = '1' then
                     v.descState := READ_S;
                  else
                     v.descState := WRITE_S;
                  end if;
               end if;
            end if;

         ----------------------------------------------------------------------
         when WRITE_S =>
            if CHAN_COUNT_G > 1 then
               descIndex := conv_integer(r.descRetNum(DESC_SIZE_C-1 downto 1));
            else
               descIndex := 0;
            end if;

            -- Write address channel
            v.axiWriteMaster.awaddr := r.wrMemAddr;
            v.axiWriteMaster.awlen  := x"00";  -- Single transaction

            -- Write data channel
            v.axiWriteMaster.wlast := '1';
            v.axiWriteMaster.wstrb := resize(x"FF", 128);

            -- Descriptor data
--            v.axiWriteMaster.wdata(63 downto 56) := dmaWrDescRet(descIndex).dest;                -- Bits 63-56 - data stream channel ID
--            v.axiWriteMaster.wdata(55 downto 32) := dmaWrDescRet(descIndex).size(23 downto 0);   -- Bits 55-32 - transfer size = 24 bits
--            v.axiWriteMaster.wdata(31 downto 24) := dmaWrDescRet(descIndex).firstUser;           -- Bits 31-24 - First user data
--            v.axiWriteMaster.wdata(23 downto 16) := dmaWrDescRet(descIndex).lastUser;            -- Bits 23-16 - Last user data
--            v.axiWriteMaster.wdata(15 downto 4)  := dmaWrDescRet(descIndex).buffId(11 downto 0); -- Bits 15-4  - 12 bit buffer ID
--            v.axiWriteMaster.wdata(3)            := dmaWrDescRet(descIndex).continue;            -- Bit 3      - Continue signal
--            v.axiWriteMaster.wdata(2 downto 0)   := dmaWrDescRet(descIndex).result;              -- Bits 2-0   - Result


            -- New descriptor structure
            v.axiWriteMaster.wdata(127 downto 112) := dmaWrDescRet(descIndex).dest;       -- 16 bits
            v.axiWriteMaster.wdata(111 downto 104) := dmaWrDescRet(descIndex).firstUser;  -- 8  bits
            v.axiWriteMaster.wdata(103 downto  96) := dmaWrDescRet(descIndex).lastUser;   -- 8  bits
            v.axiWriteMaster.wdata(95  downto  64) := dmaWrDescRet(descIndex).size;       -- 32 bits
            v.axiWriteMaster.wdata(63  downto  32) := dmaWrDescRet(descIndex).buffId;     -- 32 bits
            v.axiWriteMaster.wdata(31)             := '1';
            v.axiWriteMaster.wdata(30  downto   4) := (others => '0');
            v.axiWriteMaster.wdata(3)              := dmaWrDescRet(descIndex).continue;
            v.axiWriteMaster.wdata(2   downto   0) := dmaWrDescRet(descIndex).result;


            -- Encoded channel into upper destination bits
            if CHAN_COUNT_G > 1 then
               v.axiWriteMaster.wdata(127 downto 128-CHAN_SIZE_C) := toSlv(descIndex, CHAN_SIZE_C);
            end if;

            v.axiWriteMaster.awvalid := '1';
            v.axiWriteMaster.wvalid  := '1';
            v.wrIndex                := r.wrIndex + 1;
            v.descState              := WAIT_S;

            v.dmaWrDescRetAck(descIndex) := '1';

         ----------------------------------------------------------------------
         when READ_S =>
            if CHAN_COUNT_G > 1 then
               descIndex := conv_integer(r.descRetNum(DESC_SIZE_C-1 downto 1));
            else
               descIndex := 0;
            end if;

            -- Write address channel
            v.axiWriteMaster.awaddr := r.rdMemAddr;
            v.axiWriteMaster.awlen  := x"00";  -- Single transaction

            -- Write data channel
            v.axiWriteMaster.wlast := '1';
            v.axiWriteMaster.wstrb := resize(x"FF", 128);

            -- Descriptor data
            v.axiWriteMaster.wdata(127 downto 64) := x"0000000000000001";
            v.axiWriteMaster.wdata(63 downto 32)  := dmaRdDescRet(descIndex).buffId; -- Dma read desc buffer id
            v.axiWriteMaster.wdata(31 downto 4)   := (others => '0');
            v.axiWriteMaster.wdata(3)             := '0';
            v.axiWriteMaster.wdata(2 downto 0)    := dmaRdDescRet(descIndex).result; -- Dma read desc index

            v.axiWriteMaster.awvalid := '1';
            v.axiWriteMaster.wvalid  := '1';
            v.rdIndex                := r.rdIndex + 1;
            v.descState              := WAIT_S;

            v.dmaRdDescRetAck(descIndex) := '1';

         ----------------------------------------------------------------------
         when WAIT_S =>
            if v.axiWriteMaster.awvalid = '0' and v.axiWriteMaster.wvalid = '0' and
               (axiWriteSlave.bvalid = '1' or ACK_WAIT_BVALID_G = false) then
               v.intReqEn  := '1';
               v.descState := IDLE_S;
            end if;

         when others =>
            v.descState := IDLE_S;

      end case;
      
      -- Copy the lowest 64-bit word to the entire bus (refer to  "section 9.3 Narrow transfers" of the AMBA spec)
      for i in 15 downto 1 loop
         v.axiWriteMaster.wdata((64*i)+63 downto (64*i)) := v.axiWriteMaster.wdata(63 downto 0);
      end loop;      

      -- Drive interrupt, avoid false firings during ack
      if r.intReqCount /= 0 and r.intSwAckReq = '0' then
         v.interrupt := r.intEnable;
      else
         v.interrupt := '0';
      end if;

      -- Ack request from software
      if r.intSwAckReq = '1' then

         -- DSPs are done
         if intSwAckEn = '1' then
            v.intSwAckReq := '0';

            -- Just in case
            if invalidCount = '1' then     -- r.intAckCount > r.intReqCount
               v.intReqCount := (others => '0');
            else
               v.intReqCount := diffCnt;   -- r.intReqCount - r.intAckCount
            end if;
         end if;

      -- Firmware posted an entry
      elsif r.intReqEn = '1' then
         v.intReqCount := r.intReqCount + 1;
         v.intReqEn    := '0';
      end if;

      -- Engine disabled
      if r.enable = '0' then
         v.intReqEn    := '0';
         v.intReqCount := (others => '0');
         v.interrupt   := '0';
      end if;

      --------------------------------------
      -- Read Descriptor Requests
      --------------------------------------

      -- Clear requests
      for i in 0 to CHAN_COUNT_G-1 loop
         if dmaRdDescAck(i) = '1' then
            v.dmaRdDescReq(i).valid := '0';
         end if;
      end loop;

      -- Format request
      dmaRdReq                     := AXI_READ_DMA_DESC_REQ_INIT_C;
      dmaRdReq.valid               := r.rdAddrValid;
      dmaRdReq.address             := r.buffBaseAddr & r.rdAddr;
      dmaRdReq.dest                := rdFifoDout(63 downto 56);
      dmaRdReq.size(23 downto 0)   := rdFifoDout(55 downto 32);
      dmaRdReq.firstUser           := rdFifoDout(31 downto 24);
      dmaRdReq.lastUser            := rdFifoDout(23 downto 16);
      dmaRdReq.buffId(11 downto 0) := rdFifoDout(15 downto 4);
      dmaRdReq.continue            := rdFifoDout(3);

      -- Upper dest bits select channel
      if CHAN_COUNT_G > 1 then
         rdIndex                               := conv_integer(dmaRdReq.dest(7 downto 8-CHAN_SIZE_C));
         dmaRdReq.dest(7 downto 8-CHAN_SIZE_C) := (others => '0');
      else
         rdIndex := 0;
      end if;

      -- Pull next entry if we are not waiting for ack on given channel
      if r.rdFifoRd = '0' and dmaRdReq.valid = '1' and v.dmaRdDescReq(rdIndex).valid = '0' then
         v.dmaRdDescReq(rdIndex) := dmaRdReq;
         v.rdFifoRd              := '1';
      end if;

      --------------------------------------
      if r.enable = '0' then
         v.wrIndex := (others => '0');
         v.rdIndex := (others => '0');
      end if;

      -- Reset      
      if (axiRst = '1') then
         v := REG_INIT_C;
      end if;

      -- Register the variable for next clock cycle      
      rin <= v;

      -- Outputs   
      intReadSlaves(LOC_INDEX_C)  <= r.axilReadSlave;
      intWriteSlaves(LOC_INDEX_C) <= r.axilWriteSlave;

      online          <= r.online;
      interrupt       <= r.interrupt;
      acknowledge     <= r.acknowledge;
      dmaWrDescAck    <= r.dmaWrDescAck;
      dmaWrDescRetAck <= r.dmaWrDescRetAck;
      dmaRdDescReq    <= r.dmaRdDescReq;
      dmaRdDescRetAck <= r.dmaRdDescRetAck;
      axiWriteMaster  <= r.axiWriteMaster;
      axiRdCache      <= r.buffRdCache;
      axiWrCache      <= r.buffWrCache;

   end process comb;

   seq : process (axiClk) is
   begin
      if (rising_edge(axiClk)) then
         r <= rin after TPD_G;
      end if;
   end process seq;

end rtl;
