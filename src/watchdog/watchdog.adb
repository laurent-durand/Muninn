-- src/watchdog/watchdog.adb
-- Muninn watchdog — Ada 2012.
-- Monitors the liveness of each muninn sub-process via heartbeat files
-- written to /run/muninn/<component>.hb.
-- If a component misses MISSED_BEATS consecutive beats it is restarted
-- via Ada.Command_Line / POSIX exec.
-- Ada's strong typing and tasking model make it ideal for a safety-critical
-- supervisor process.

with Ada.Text_IO;          use Ada.Text_IO;
with Ada.Integer_Text_IO;  use Ada.Integer_Text_IO;
with Ada.Calendar;         use Ada.Calendar;
with Ada.Directories;      use Ada.Directories;
with Ada.Command_Line;
with Ada.Strings.Fixed;    use Ada.Strings.Fixed;
with GNAT.OS_Lib;          use GNAT.OS_Lib;

procedure Watchdog is

   -- ── Constants ────────────────────────────────────────────────────────────
   BEAT_DIR      : constant String  := "/run/muninn/";
   POLL_INTERVAL : constant Duration := 2.0;   -- seconds
   MISSED_BEATS  : constant Natural  := 3;

   -- ── Component registry ───────────────────────────────────────────────────
   type Component_Id is (Core, Net, Api, Config, Rules, Stats, Logs, Syscall,
                          Fanout, Tui);

   type Component_Spec is record
      Name    : String (1 .. 12);
      Cmd     : String (1 .. 64);
      Missed  : Natural;
      Last_Ok : Time;
   end record;

   Components : array (Component_Id) of Component_Spec := (
      Core    => (Name => "core        ", Cmd => "/usr/lib/muninn/muninn-core         ", others => <>),
      Net     => (Name => "net         ", Cmd => "/usr/lib/muninn/muninn-net          ", others => <>),
      Api     => (Name => "api         ", Cmd => "/usr/lib/muninn/muninn-api          ", others => <>),
      Config  => (Name => "config      ", Cmd => "/usr/lib/muninn/muninn-config       ", others => <>),
      Rules   => (Name => "rules       ", Cmd => "/usr/lib/muninn/muninn-rules        ", others => <>),
      Stats   => (Name => "stats       ", Cmd => "/usr/lib/muninn/muninn-stats        ", others => <>),
      Logs    => (Name => "logs        ", Cmd => "/usr/lib/muninn/muninn-logs         ", others => <>),
      Syscall => (Name => "syscall     ", Cmd => "/usr/lib/muninn/muninn-syscall      ", others => <>),
      Fanout  => (Name => "fanout      ", Cmd => "/usr/lib/muninn/muninn-fanout       ", others => <>),
      Tui     => (Name => "tui         ", Cmd => "/usr/lib/muninn/muninn-tui          ", others => <>)
   );

   -- ── Heartbeat check ──────────────────────────────────────────────────────
   function Heartbeat_Path (C : Component_Id) return String is
      Name : constant String := Ada.Strings.Fixed.Trim
                                  (Components (C).Name, Ada.Strings.Right);
   begin
      return BEAT_DIR & Name & ".hb";
   end Heartbeat_Path;

   function Is_Alive (C : Component_Id) return Boolean is
      Path   : constant String := Heartbeat_Path (C);
      M_Time : Time;
   begin
      if not Exists (Path) then return False; end if;
      M_Time := Modification_Time (Path);
      return (Clock - M_Time) < Duration (MISSED_BEATS) * POLL_INTERVAL * 2.0;
   exception
      when others => return False;
   end Is_Alive;

   -- ── Restart ──────────────────────────────────────────────────────────────
   procedure Restart_Component (C : Component_Id) is
      Cmd  : constant String  := Ada.Strings.Fixed.Trim
                                   (Components (C).Cmd, Ada.Strings.Right);
      Args : constant Argument_List := (1 => new String'(""));
      Pid  : Process_Id;
   begin
      Put_Line ("[watchdog] restarting " & Ada.Strings.Fixed.Trim
                  (Components (C).Name, Ada.Strings.Right));
      Pid := Non_Blocking_Spawn (Cmd, Args);
      if Pid = Invalid_Pid then
         Put_Line ("[watchdog] FAILED to restart " &
                     Ada.Strings.Fixed.Trim (Components (C).Name, Ada.Strings.Right));
      end if;
   exception
      when GNAT.OS_Lib.Invalid_Data => null;  -- executable not found; log only
   end Restart_Component;

   -- ── Watchdog task ─────────────────────────────────────────────────────────
   task Watchdog_Task;

   task body Watchdog_Task is
      Now : Time;
   begin
      -- Initialise last-ok timestamps
      Now := Clock;
      for C in Component_Id loop
         Components (C).Last_Ok := Now;
         Components (C).Missed  := 0;
      end loop;

      loop
         delay POLL_INTERVAL;
         for C in Component_Id loop
            if Is_Alive (C) then
               Components (C).Missed  := 0;
               Components (C).Last_Ok := Clock;
            else
               Components (C).Missed := Components (C).Missed + 1;
               if Components (C).Missed >= MISSED_BEATS then
                  Restart_Component (C);
                  Components (C).Missed := 0;
               end if;
            end if;
         end loop;
      end loop;
   end Watchdog_Task;

begin
   Put_Line ("[watchdog] muninn watchdog starting");
   -- Watchdog_Task runs concurrently; main task blocks here.
   loop
      delay 60.0;
      Put_Line ("[watchdog] tick — all tasks supervised");
   end loop;
end Watchdog;
