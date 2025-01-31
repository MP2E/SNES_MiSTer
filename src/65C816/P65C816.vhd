library IEEE;
use IEEE.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.P65816_pkg.all;

entity P65C816 is
    port( 
        CLK			: in std_logic;
		  RST_N		: in std_logic;
		  CE			: in std_logic;
		  
		  RDY_IN		: in std_logic;
        NMI_N		: in std_logic;  
		  IRQ_N		: in std_logic; 
		  ABORT_N	: in std_logic;   -- just for WAI only
        D_IN		: in std_logic_vector(7 downto 0);
        D_OUT     : out std_logic_vector(7 downto 0);
        A_OUT     : out std_logic_vector(23 downto 0);
        WE  		: out std_logic; 
		  RDY_OUT 	: out std_logic;
		  VPA 		: out std_logic;
		  VDA 		: out std_logic;
		  MLB 		: out std_logic;
		  VPB 		: out std_logic;
		  
		  BRK_OUT	: out std_logic;
		  DBG_REG	: in std_logic_vector(7 downto 0);
		  DBG_DAT_IN		: in std_logic_vector(7 downto 0);
		  DBG_DAT_OUT	: out std_logic_vector(7 downto 0);
		  DBG_DAT_WR	: in std_logic
    );
end P65C816;

architecture rtl of P65C816 is

	signal A, X, Y, D, SP, T : std_logic_vector(15 downto 0);
	signal PBR, DBR : std_logic_vector(7 downto 0);
	signal P    : std_logic_vector(8 downto 0);
	signal PC    : std_logic_vector(15 downto 0);
	
	signal DR : std_logic_vector(7 downto 0);
	signal EF, XF, MF, oldXF : std_logic;
	signal SB, DB : std_logic_vector(15 downto 0);
	signal EN : std_logic;
   signal MC : MCode_r;
	signal IR, NextIR : std_logic_vector(7 downto 0);
	signal STATE, NextState : unsigned(3 downto 0);
	signal LAST_CYCLE : std_logic;
	signal GotInterrupt : std_logic;
	signal IsResetInterrupt, IsNMIInterrupt, IsIRQInterrupt, IsABORTInterrupt, IsCOPInterrupt : std_logic;
	signal JumpTaken, JumpNoOverflow, IsBranchCycle1 : std_logic;
	signal w16 : std_logic;
	signal DLNoZero : std_logic;
	signal WAIExec, STPExec : std_logic;
	signal NMI_SYNC, IRQ_SYNC : std_logic;
	signal NMI_ACTIVE, IRQ_ACTIVE : std_logic;
	signal OLD_NMI_N : std_logic;
	signal ADDR_BUS : std_logic_vector(23 downto 0);
	
	-- ALU 
	signal AluR: std_logic_vector(15 downto 0);
	signal AluIntR: std_logic_vector(15 downto 0);
	signal CO, VO, SO, ZO : std_logic;
	
	-- AddrGen 
	signal AA: std_logic_vector(16 downto 0);
	signal AB: std_logic_vector(7 downto 0);
	signal AALCarry : std_logic;
	signal DX: std_logic_vector(15 downto 0);
		
	-- Debug
	signal DBG_DAT_WRr : std_logic;
	signal DBG_BRK_ADDR : std_logic_vector(23 downto 0) := (others => '1');
	signal DBG_CTRL : std_logic_vector(7 downto 0) := (others => '0');
	signal DBG_RUN_LAST : std_logic;
	signal DBG_NEXT_PC: std_logic_vector(15 downto 0);
	signal JSR_RET_ADDR: std_logic_vector(23 downto 0);
	signal JSR_FOUND : std_logic;
	
begin
	EN <= RDY_IN and CE and not WAIExec and not STPExec;
	
	IsBranchCycle1 <= '1' when IR(4 downto 0) = "10000" and STATE = "0001" else '0';
	process(IR, P)
	begin
		case IR(7 downto 5) is
			when "000" => JumpTaken <= not P(7); -- BPL
			when "001" => JumpTaken <=     P(7); -- BMI
			when "010" => JumpTaken <= not P(6); -- BVC
			when "011" => JumpTaken <=     P(6); -- BVS
			when "100" => JumpTaken <= not P(0); -- BCC
			when "101" => JumpTaken <=     P(0); -- BCS
			when "110" => JumpTaken <= not P(1); -- BNE
			when "111" => JumpTaken <=     P(1); -- BEQ
			when others => JumpTaken <= '0';
		end case; 
	end process;
	
	DLNoZero <= '0' when D(7 downto 0) = x"00" else '1';

	NextIR <= IR when (STATE /= "0000") else
				 x"00" when GotInterrupt = '1' else 
				 D_IN; 
	
	process(MC, MF, XF, EF, IR, STATE, AALCarry, JumpNoOverflow, IsBranchCycle1, JumpTaken, DLNoZero)
	begin
		case MC.STATE_CTRL is
			when "000" => 
				NextState <= STATE + 1; 
			when "001" => 
				if (AALCarry = '0' and (XF = '1' or EF = '1')) then
					NextState <= STATE + 2;
				else
					NextState <= STATE + 1;
				end if;
			when "010" => 
				if IsBranchCycle1 = '1' and JumpTaken = '1' then
					NextState <= "0010";
				else
					NextState <= "0000";
				end if; 
			when "011" => 
				if JumpNoOverflow = '1' then
					NextState <= "0000";
				else
					NextState <= STATE + 1;
				end if; 
			when "100" => 
				if (MC.LOAD_AXY(1) = '0' and MF = '0' and EF = '0') or 
					(MC.LOAD_AXY(1) = '1' and XF = '0' and EF = '0') then
					NextState <= STATE + 1; 
				else
					NextState <= "0000";
				end if; 
			when "101" => 
				if DLNoZero = '1' and EF = '0' then
					NextState <= STATE + 1; 
				else
					NextState <= STATE + 2; 
				end if;
			when "110" => 
				if (MC.LOAD_AXY(1) = '0' and MF = '0' and EF = '0') or 
					(MC.LOAD_AXY(1) = '1' and XF = '0' and EF = '0') then
					NextState <= STATE + 1; 
				else
					NextState <= STATE + 2; 
				end if; 
			when "111" => 
				if EF = '0' then							--BRK,COP,RTI Native mode
					NextState <= STATE + 1; 
				elsif EF = '1' and IR = x"40" then	--RTI Emulation mode
					NextState <= "0000";
				else											--BRK,COP Emulation mode
					NextState <= STATE + 2; 
				end if; 
			when others => null;
		end case;
	end process;
	
	LAST_CYCLE <= '1' when NextState = "0000" else '0';
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			STATE <= (others=>'0');
			IR <= (others=>'0');
		elsif rising_edge(CLK) then
			if EN = '1' then
				IR <= NextIR;
				STATE <= NextState;
			end if;
		end if;
	end process; 
	 
	
	MCode: entity work.MCode
	port map (
		CLK		=> CLK,
		RST_N		=> RST_N,
		EN			=> EN,
		IR			=> NextIR,
		STATE		=> NextState,
		M			=> MC
	);
	
	AddrGen: entity work.AddrGen
	port map (
		CLK   		=> CLK,
		RST_N   		=> RST_N,
		EN   			=> EN,
		LOAD_PC   	=> MC.LOAD_PC,
		PCDec 		=> CO,
		GotInterrupt=> GotInterrupt,
		ADDR_CTRL	=> MC.ADDR_CTRL,
		IND_CTRL		=> MC.IND_CTRL,
		D_IN 			=> D_IN,
		X     		=> X, 
		Y     		=> Y, 
		D     		=> D,
		S     		=> SP,
		T     		=> T,
		DR    		=> DR,
		DBR    		=> DBR,
		e6502			=> EF,
		PC     		=> PC, 
		AA     		=> AA, 
		AB     		=> AB, 
		DX     		=> DX,
		AALCarry     => AALCarry, 
		JumpNoOfl 	=> JumpNoOverflow,
		DBG_NEXT_PC => DBG_NEXT_PC
	);
	
	
	w16 <= '1' when MC.ALU_CTRL.w16 = '1' else	
			 '0' when IR = x"EB" or IR = x"AB" else	--for XBA,PLB
			 '1' when (IR = x"44" or IR = x"54") and STATE = "0101" else	--for MVN/MVP DEC A
			 '1' when (MC.LOAD_AXY(1) = '0') and MF = '0' and EF = '0' else
			 '1' when (MC.LOAD_AXY(1) = '1') and XF = '0' and EF = '0' else
			 '0';
			 
	SB <= A           when MC.BUS_CTRL(5 downto 3) = "000" else
		   X           when MC.BUS_CTRL(5 downto 3) = "001" else
		   Y           when MC.BUS_CTRL(5 downto 3) = "010" else
		   D           when MC.BUS_CTRL(5 downto 3) = "011" else
		   T           when MC.BUS_CTRL(5 downto 3) = "100" else
			SP          when MC.BUS_CTRL(5 downto 3) = "101" else
			x"00" & PBR when MC.BUS_CTRL(5 downto 3) = "110" else
			x"00" & DBR when MC.BUS_CTRL(5 downto 3) = "111" else
			x"0000";
	
	DB <= x"00" & D_IN when MC.BUS_CTRL(2 downto 0) = "000" else
		   D_IN & DR    when MC.BUS_CTRL(2 downto 0) = "001" else
		   SB           when MC.BUS_CTRL(2 downto 0) = "010" else
		   D            when MC.BUS_CTRL(2 downto 0) = "011" else
		   T            when MC.BUS_CTRL(2 downto 0) = "100" else
			x"0001"      when MC.BUS_CTRL(2 downto 0) = "101" else
			x"0000";
			
	ALU: entity work.ALU
	port map (
		CTRL   	=> MC.ALU_CTRL,
		L     	=> SB,
		R     	=> DB,
		w16     	=> w16,
		bcd     	=> P(3),
		CI   	 	=> P(0),
		VI  		=> P(6),
		SI  		=> P(7),
		CO   		=> CO,
		VO    	=> VO,
		SO   		=> SO,
		ZO   		=> ZO,
		RES		=> AluR,
		IntR		=> AluIntR
	);

	MF <= P(5);
	XF <= P(4);
	EF <= P(8);
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			A <= (others=>'0');
			X <= (others=>'0');
			Y <= (others=>'0');
			SP <= x"0100";
			oldXF <= '1';
		elsif rising_edge(CLK) then
			if (IR = x"FB" and P(0) = '1' and MC.LOAD_P = "101") then
				X(15 downto 8) <= x"00";
				Y(15 downto 8) <= x"00";
				SP(15 downto 8) <= x"01";
				oldXF <= '1';
			elsif EN = '1' then
				if MC.LOAD_AXY = "110" then 
					if MC.BYTE_SEL(1) = '1' and XF = '0' and EF = '0' then 
						X(15 downto 8) <= AluR(15 downto 8);
						X(7 downto 0) <= AluR(7 downto 0);
					elsif MC.BYTE_SEL(0) = '1' and (XF = '1' or EF = '1') then
						X(7 downto 0) <= AluR(7 downto 0);
						X(15 downto 8) <= x"00";
					end if;
				end if;
				if MC.LOAD_AXY = "101" then 
					if IR = x"EB" then	--XBA
						A(15 downto 8) <= A(7 downto 0);
						A(7 downto 0) <= A(15 downto 8);
					elsif (MC.BYTE_SEL(1) = '1' and MF = '0' and EF = '0') or
						(MC.BYTE_SEL(1) = '1' and w16 = '1') then
						A(15 downto 8) <= AluR(15 downto 8);
						A(7 downto 0) <= AluR(7 downto 0);
					elsif MC.BYTE_SEL(0) = '1' and (MF = '1' or EF = '1') then
						A(7 downto 0) <= AluR(7 downto 0);
					end if;
				end if;
				if MC.LOAD_AXY = "111" then 
					if MC.BYTE_SEL(1) = '1' and XF = '0' and EF = '0'  then
						Y(15 downto 8) <= AluR(15 downto 8);
						Y(7 downto 0) <= AluR(7 downto 0);
					elsif MC.BYTE_SEL(0) = '1' and (XF = '1' or EF = '1') then
						Y(7 downto 0) <= AluR(7 downto 0);
						Y(15 downto 8) <= x"00";
					end if;
				end if; 
				
				oldXF <= XF;
				if XF = '1' and oldXF = '0' and EF = '0' then
					X(15 downto 8) <= x"00";
					Y(15 downto 8) <= x"00";
				end if;
				
				case MC.LOAD_SP is
					when "000" => null;
					when "001"=> 
						if EF = '0' then
							SP <= std_logic_vector(unsigned(SP) + 1);
						else
							SP(7 downto 0) <= std_logic_vector(unsigned(SP(7 downto 0)) + 1);
						end if;
					when "010" => 
						if MC.BYTE_SEL(1) = '0' and w16 = '1' then
							if EF = '0' then
								SP <= std_logic_vector(unsigned(SP) + 1);
							else
								SP(7 downto 0) <= std_logic_vector(unsigned(SP(7 downto 0)) + 1);
							end if;
						end if;
					when "011" => 
						if EF = '0' then
							SP <= std_logic_vector(unsigned(SP) - 1);
						else
							SP(7 downto 0) <= std_logic_vector(unsigned(SP(7 downto 0)) - 1);
						end if;
					when "100" => 
						if EF = '0' then
							SP <= A;
						else
							SP <= x"01" & A(7 downto 0);
						end if;
					when "101" => 
						if EF = '0' then
							SP <= X;
						else
							SP <= x"01" & X(7 downto 0);
						end if;
					when others => null;
				end case;
			end if; 
		end if;
	end process;
	
	--Status register
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			P <= "100110100";
		elsif rising_edge(CLK) then
			if EN = '1' then
				case MC.LOAD_P is
					when "000" => P <= P;
					when "001" => 
						if (MC.LOAD_AXY(1) = '0' and MC.BYTE_SEL(0) = '1' and (MF = '1' or EF = '1')) or		--A/Mem 8bit
							(MC.LOAD_AXY(1) = '1' and MC.BYTE_SEL(0) = '1' and (XF = '1' or EF = '1')) or		--X/Y 8bit
							(MC.LOAD_AXY(1) = '0' and MC.BYTE_SEL(1) = '1' and (MF = '0' and EF = '0')) or	--A/Mem 16bit
							(MC.LOAD_AXY(1) = '1' and MC.BYTE_SEL(1) = '1' and (XF = '0' and EF = '0')) or	--X/Y 16bit
							(MC.LOAD_AXY(1) = '0' and MC.BYTE_SEL(1) = '1' and w16 = '1') or						--A/Mem 16bit
							IR = x"EB" or IR = x"AB" then
							P(1 downto 0) <= ZO & CO; P(7 downto 6) <= SO & VO; -- ALU
						end if;
					when "010" => P(2) <= '1'; P(3) <= '0';		-- BRK/COP
					when "011" => P(7 downto 6) <= D_IN(7 downto 6); P(5) <= D_IN(5) or EF; P(4) <= D_IN(4) or EF; P(3 downto 0) <= D_IN(3 downto 0); -- RTI/PLP
					when "100" => 
						case IR(7 downto 6) is
							when "00" => P(0) <= IR(5); -- CLC/SEC 18/38
							when "01" => P(2) <= IR(5); -- CLI/SEI 58/78
							when "10" => P(6) <= '0';   -- CLV B8
							when "11" => P(3) <= IR(5); -- CLD/SED D8/F8
							when others => null;
						end case;
					when "101" => 						-- XCE
						P(8) <= P(0); P(0) <= P(8);
						if P(0) = '1' then
							P(4) <= '1';
							P(5) <= '1';
						end if;
					when "110" => 
						case IR(5) is
							when '1' => P(7 downto 0) <= P(7 downto 0) or (DR(7 downto 6) & (DR(5) and not EF) & (DR(4) and not EF) & DR(3 downto 0)); -- SEP
							when '0' => P(7 downto 0) <= P(7 downto 0) and (not (DR(7 downto 6) & (DR(5) and not EF) & (DR(4) and not EF) & DR(3 downto 0))); -- REP
							when others => null;
						end case;
					when "111" => P(1) <= ZO; 	-- BIT IMM
					when others => null;
				end case;
			end if;
		end if;
	end process;

	--
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			T <= (others=>'0');
			DR <= (others=>'0');
			D <= (others=>'0');
			PBR <= (others=>'0');
			DBR <= (others=>'0');
		elsif rising_edge(CLK) then
			if EN = '1' then
				DR <= D_IN;
				
				case MC.LOAD_T is
					when "01" => 
						if MC.BYTE_SEL(1) = '1' then
							T(15 downto 8) <= D_IN;
						else 
							T(7 downto 0) <= D_IN;
						end if;
					when "10" => 
						T <= AluR;
					when others => null;
				end case;
				
				case MC.LOAD_DKB is
					when "01" => 
						D <= AluIntR;
					when "10" => 
						if IR = x"00" or IR = x"02" then	--BRK/COP reset PBR
							PBR <= (others=>'0');
						else
							PBR <= D_IN;
						end if;
					when "11" => 
						if IR = x"44" or IR = x"54" then	--MVN/MVP 
							DBR <= D_IN;
						else
							DBR <= AluIntR(7 downto 0);
						end if;
					when others => null;
				end case;
			end if;
		end if;
	end process;
	
	--Data bus
	D_OUT <= P(7) & P(6) & (P(5) or EF) & (P(4) or (not (GotInterrupt) and EF)) & P(3 downto 0) when MC.OUT_BUS = "001" else
				PC(15 downto 8) when MC.OUT_BUS = "010" and MC.BYTE_SEL(1) = '1' else
				PC(7 downto 0) when MC.OUT_BUS = "010" and MC.BYTE_SEL(1) = '0' else
				AA(15 downto 8) when MC.OUT_BUS = "011" and MC.BYTE_SEL(1) = '1' else
				AA(7 downto 0) when MC.OUT_BUS = "011" and MC.BYTE_SEL(1) = '0' else
				PBR when MC.OUT_BUS = "100" else
				SB(15 downto 8) when MC.OUT_BUS = "101" and MC.BYTE_SEL(1) = '1' else
				SB(7 downto 0) when MC.OUT_BUS = "101" and MC.BYTE_SEL(1) = '0' else
				DR when MC.OUT_BUS = "110" else
				x"00";
		
	process(MC, IsResetInterrupt)
	begin
		WE <= '1';
		if MC.OUT_BUS /= "000" and IsResetInterrupt = '0' then
			WE <= '0';
		end if;
	end process;

	
	--Interrupts
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			OLD_NMI_N <= '1';
			NMI_SYNC <= '0';
			IRQ_SYNC <= '0';
		elsif rising_edge(CLK) then
			if CE = '1' and IsResetInterrupt = '0' then
				OLD_NMI_N <= NMI_N;
				if NMI_N = '0' and OLD_NMI_N = '1' and NMI_SYNC = '0' then
					NMI_SYNC <= '1';
				elsif NMI_ACTIVE = '1' and LAST_CYCLE = '1' and EN = '1' then
					NMI_SYNC <= '0';
				end if;
				IRQ_SYNC <= not IRQ_N;
			end if;
		end if;
	end process; 
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			IsResetInterrupt <= '1';
			IsNMIInterrupt <= '0';
			IsIRQInterrupt <= '0';
			GotInterrupt <= '1';
			NMI_ACTIVE <= '0';
			IRQ_ACTIVE <= '0';
		elsif rising_edge(CLK) then
			if RDY_IN = '1' and CE = '1' then
				NMI_ACTIVE <= NMI_SYNC;
				IRQ_ACTIVE <= not IRQ_N and not P(2);
				
				if LAST_CYCLE = '1' and EN = '1' then
					if GotInterrupt = '0' then
						GotInterrupt <= IRQ_ACTIVE or NMI_ACTIVE;
						NMI_ACTIVE <= '0';
					else
						GotInterrupt <= '0';
					end if;
					
					IsResetInterrupt <= '0';
					IsNMIInterrupt <= NMI_ACTIVE;
					IsIRQInterrupt <= IRQ_ACTIVE;
				end if;
			end if;
		end if;
	end process; 
	
	IsCOPInterrupt <= '1' when IR = x"02" else '0';
	IsABORTInterrupt <= '0';
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			WAIExec <= '0';
			STPExec <= '0';
		elsif rising_edge(CLK) then
			if EN = '1' and GotInterrupt = '0' then
				if STATE = "0000" then 
					if D_IN = x"CB" then			-- WAI
						WAIExec <= '1';
					elsif D_IN = x"DB" then		-- STP
						STPExec <= '1';
					end if;
				end if;
			end if;
			
			if RDY_IN = '1' and CE = '1' then
				if ( NMI_SYNC = '1' or IRQ_SYNC = '1' or ABORT_N = '0' ) and WAIExec = '1' then
					WAIExec <= '0';
				end if;
			end if;
		end if;
	end process; 
	
	
	--Address bus
	process(MC, PC, AA, DX, SP, EF, PBR, DBR, AB, IsResetInterrupt, IsABORTInterrupt, IsNMIInterrupt, IsIRQInterrupt, IsCOPInterrupt)
	variable ADDR_INC : unsigned(15 downto 0);
	begin
		ADDR_INC := (15 downto 2 => '0', 1 => MC.ADDR_INC(1), 0 => MC.ADDR_INC(0));
		case MC.ADDR_BUS is
			when "000" => 
				ADDR_BUS(23 downto 0) <= PBR & PC; 
			when "001"=> 
				ADDR_BUS(23 downto 0) <= std_logic_vector((unsigned(DBR) & x"0000") + (x"00" & unsigned(AA(15 downto 0))) + (x"00" & ADDR_INC));
			when "010" => 
				if EF = '0' then
					ADDR_BUS(23 downto 0) <= x"00" & SP;
				else
					ADDR_BUS(23 downto 0) <= x"00" & x"01" & SP(7 downto 0);
				end if;
			when "011" => 
				ADDR_BUS(23 downto 0) <= x"00" & std_logic_vector(unsigned(DX) + ADDR_INC);
			when "100" => 
				ADDR_BUS(23 downto 4) <= x"00" & "11111111111" & EF;
				if IsResetInterrupt = '1' then
					ADDR_BUS(3 downto 0) <= "110" & MC.ADDR_INC(0);		--FFFC/D
				elsif IsABORTInterrupt = '1' then
					ADDR_BUS(3 downto 0) <= "100" & MC.ADDR_INC(0);		--FFF8/8, FFE8/9
				elsif IsNMIInterrupt = '1' then
					ADDR_BUS(3 downto 0) <= "101" & MC.ADDR_INC(0);		--FFFA/B, FFEA/B
				elsif IsIRQInterrupt = '1' then
					ADDR_BUS(3 downto 0) <= "111" & MC.ADDR_INC(0);		--FFFE/F, FFEE/F
				elsif IsCOPInterrupt = '1' then
					ADDR_BUS(3 downto 0) <= "010" & MC.ADDR_INC(0);		--FFF4/5, FFE4/5
				else			--BRK Interrupt
					ADDR_BUS(3 downto 0) <= EF & "11" & MC.ADDR_INC(0);	--FFFE/F, FFE6/7
				end if;
			when "101"=> 
				ADDR_BUS(23 downto 0) <= std_logic_vector((unsigned(AB) & x"0000") + ("0000000" & unsigned(AA)) + (x"00" & ADDR_INC));
			when "110"=> 
				ADDR_BUS(23 downto 0) <= x"00" & std_logic_vector(unsigned(AA(15 downto 0)) + ADDR_INC);
			when "111"=> 
				ADDR_BUS(23 downto 0) <= PBR & std_logic_vector(unsigned(AA(15 downto 0)) + ADDR_INC);
			when others => null;
		end case;
	end process;
	
	A_OUT <= ADDR_BUS;

	process(MC, IR, LAST_CYCLE, STATE, IRQ_ACTIVE, NMI_ACTIVE)
		variable rmw : std_logic;
		variable twoCls : std_logic;
	begin
		 if IR = x"06" or IR = x"0E" or IR = x"16" or IR = x"1E" or 
			 IR = x"C6" or IR = x"CE" or IR = x"D6" or IR = x"DE" or 
			 IR = x"E6" or IR = x"EE" or IR = x"F6" or IR = x"FE" or 
			 IR = x"46" or IR = x"4E" or IR = x"56" or IR = x"5E" or 
			 IR = x"26" or IR = x"2E" or IR = x"36" or IR = x"3E" or 
			 IR = x"66" or IR = x"6E" or IR = x"76" or IR = x"7E" or 
			 IR = x"14" or IR = x"1C" or IR = x"04" or IR = x"0C" then
			rmw := '1';
		else
			rmw := '0';
		end if;
				
		if MC.ADDR_BUS = "100" then
			VPB <= '0';
		else
			VPB <= '1';
		end if;

		if (MC.ADDR_BUS = "001" or MC.ADDR_BUS = "011") and rmw = '1' then
			MLB <= '0';
		else
			MLB <= '1';
		end if;
		
		if LAST_CYCLE = '1' and STATE = 1 and MC.VA = "00" then
			twoCls := '1';
		else
			twoCls := '0';
		end if;
		VDA <= MC.VA(1);
		VPA <= MC.VA(0) or (twoCls and (IRQ_ACTIVE or NMI_ACTIVE));
	end process;
	
	RDY_OUT <= EN;
	
	
	--debug
	process(CLK, RST_N)
		variable AFTER_JSR_PC: std_logic_vector(15 downto 0);
		variable JSRS: std_logic;
	begin
		if RST_N = '0' then
			BRK_OUT <= '0';
			DBG_RUN_LAST <= '0';
			JSR_RET_ADDR <= (others=>'0');
			JSR_FOUND <= '0';
		elsif rising_edge(CLK) then
			if CE = '1' and RDY_IN = '1' then
				if NextIR = x"20" or NextIR = x"22" or NextIR = x"FC" then
					JSRS := '1';
				else
					JSRS := '0';
				end if;
				if NextIR = x"20" or NextIR = x"FC" then
					AFTER_JSR_PC := std_logic_vector(unsigned(PC) + 3);
				else
					AFTER_JSR_PC := std_logic_vector(unsigned(PC) + 4);
				end if;

				BRK_OUT <= '0';
				if DBG_CTRL(0) = '1' then			--step
					if LAST_CYCLE = '1' then
						if DBG_CTRL(1) = '1' then	--trace
							BRK_OUT <= '1';
							JSR_FOUND <= '0';
						elsif JSR_FOUND = '0' then
							BRK_OUT <= '1';
							if JSRS = '1' then
								JSR_RET_ADDR <= PBR & AFTER_JSR_PC;
								JSR_FOUND <= '1';
							end if;
						elsif JSR_RET_ADDR(15 downto 0) = DBG_NEXT_PC and JSR_RET_ADDR(23 downto 16) = PBR and JSR_FOUND = '1' then
							BRK_OUT <= '1';
							if JSRS = '1' then
								JSR_RET_ADDR <= PBR & AFTER_JSR_PC;
								JSR_FOUND <= '1';
							else
								JSR_FOUND <= '0';
							end if;
						end if;
					end if;
				elsif DBG_CTRL(2) = '1' then		--opcode address break
					if LAST_CYCLE = '1' and DBG_BRK_ADDR(15 downto 0) = DBG_NEXT_PC and DBG_BRK_ADDR(23 downto 16) = PBR then
						BRK_OUT <= '1';
					end if;
				elsif DBG_CTRL(3) = '1' then		--read/write address break
					if DBG_BRK_ADDR = ADDR_BUS and MC.VA = "10" then
						BRK_OUT <= '1';
					end if;
				end if;
			end if;
			
			DBG_RUN_LAST <= DBG_CTRL(7);			--run
			if DBG_CTRL(7) = '1' and DBG_RUN_LAST = '0' then
				BRK_OUT <= '0';
			end if;
		end if;
	end process;
	
	process(RST_N, CLK, DBG_REG, A, X, Y, PC, P, SP, D, PBR, DBR, MC, AA, AB, DX, 
			  GotInterrupt, IsResetInterrupt, IsNMIInterrupt, IsIRQInterrupt, RDY_IN, EN, WAIExec, STPExec,
			  DBG_BRK_ADDR, DBG_CTRL)
	begin
		case DBG_REG is
			when x"00" => DBG_DAT_OUT <= A(7 downto 0);
			when x"01" => DBG_DAT_OUT <= A(15 downto 8);
			when x"02" => DBG_DAT_OUT <= X(7 downto 0);
			when x"03" => DBG_DAT_OUT <= X(15 downto 8);
			when x"04" => DBG_DAT_OUT <= Y(7 downto 0);
			when x"05" => DBG_DAT_OUT <= Y(15 downto 8);
			when x"06" => DBG_DAT_OUT <= PC(7 downto 0);
			when x"07" => DBG_DAT_OUT <= PC(15 downto 8);
			when x"08" => DBG_DAT_OUT <= P(7 downto 0);
			when x"09" => DBG_DAT_OUT <= SP(7 downto 0);
			when x"0A" => DBG_DAT_OUT <= SP(15 downto 8);
			when x"0B" => DBG_DAT_OUT <= D(7 downto 0);
			when x"0C" => DBG_DAT_OUT <= D(15 downto 8);
			when x"0D" => DBG_DAT_OUT <= PBR;
			when x"0E" => DBG_DAT_OUT <= DBR;
			when x"0F" => DBG_DAT_OUT <= "000000" & MC.ADDR_INC;
			when x"10" => DBG_DAT_OUT <= AA(7 downto 0);
			when x"11" => DBG_DAT_OUT <= AA(15 downto 8);
			when x"12" => DBG_DAT_OUT <= AB;
			when x"13" => DBG_DAT_OUT <= DX(7 downto 0);
			when x"14" => DBG_DAT_OUT <= DX(15 downto 8);
			when x"15" => DBG_DAT_OUT <= GotInterrupt & IsResetInterrupt & IsNMIInterrupt & IsIRQInterrupt & RDY_IN & EN & WAIExec & STPExec;
			
			when x"80" => DBG_DAT_OUT <= DBG_BRK_ADDR(7 downto 0);
			when x"81" => DBG_DAT_OUT <= DBG_BRK_ADDR(15 downto 8);
			when x"82" => DBG_DAT_OUT <= DBG_BRK_ADDR(23 downto 16);
			when x"83" => DBG_DAT_OUT <= DBG_CTRL;
			when others => DBG_DAT_OUT <= x"00";
		end case; 

		if RST_N = '0' then
			DBG_DAT_WRr <= '0';
		elsif rising_edge(CLK) then
			DBG_DAT_WRr <= DBG_DAT_WR;
			if DBG_DAT_WR = '1' and DBG_DAT_WRr = '0' then
				case DBG_REG is
					when x"80" => DBG_BRK_ADDR(7 downto 0) <= DBG_DAT_IN;
					when x"81" => DBG_BRK_ADDR(15 downto 8) <= DBG_DAT_IN;
					when x"82" => DBG_BRK_ADDR(23 downto 16) <= DBG_DAT_IN;
					when x"83" => DBG_CTRL <= DBG_DAT_IN;
					when others => null;
				end case;
			end if;
		end if;
	end process;
	

end rtl;