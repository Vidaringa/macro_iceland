# Schedule tasks
#
# Registers Windows Scheduled Tasks that run R scripts. We do NOT use
# taskscheduleR::taskscheduler_create here: it writes the Rscript.exe path into
# the cmd command unquoted, so a path containing a space ("C:\Program Files\...")
# is split at the space and the task fails with
#   'C:/Program' is not recognized as an internal or external command
# We also need the task to run from the repo root, because the runner scripts
# source() sibling files via relative paths (e.g. "R/get_bond_attributes.R"),
# and scheduled tasks otherwise start in C:\Windows\System32.
#
# schedule_rscript() registers the task through PowerShell's Register-ScheduledTask
# (Rscript path quoted, working directory set to the repo root). Add future tasks
# by calling it again with a new taskname / rscript / time.

# Rscript.exe of the R install running this script. Derived from R.home() so it
# stays correct across R upgrades instead of hardcoding a version directory.
rscript_exe <- normalizePath(file.path(R.home("bin"), "Rscript.exe"), winslash = "\\")

# Repo root: this file lives in <root>/R. Resolve its path whether the file is
# run via Rscript (path is in commandArgs) or source()d interactively (ofile),
# falling back to the working directory.
this_file <- local({
  cmd  <- commandArgs(trailingOnly = FALSE)
  flag <- grep("^--file=", cmd, value = TRUE)
  if (length(flag)) return(sub("^--file=", "", flag[1]))
  if (!is.null(sys.frame(1)$ofile)) return(sys.frame(1)$ofile)
  file.path(getwd(), "R", "schedule_tasks.R")
})
repo_root <- normalizePath(file.path(dirname(this_file), ".."),
                           winslash = "\\", mustWork = FALSE)

schedule_rscript <- function(taskname, rscript, starttime,
                             logfile  = sub("\\.R$", ".log", rscript),
                             workdir  = repo_root,
                             schedule = "Daily") {
  rscript <- normalizePath(rscript, winslash = "\\", mustWork = TRUE)
  logfile <- normalizePath(logfile, winslash = "\\", mustWork = FALSE)
  workdir <- normalizePath(workdir, winslash = "\\", mustWork = TRUE)

  # cmd /c "<exe> <script> >> <log> 2>&1" with every path quoted. The outer pair
  # of quotes makes cmd keep the inner quotes; stderr is merged into the log so
  # scheduled-run errors are captured. Built here, passed to cmd by the task.
  cmd_args <- sprintf('/c ""%s" "%s" >> "%s" 2>&1"', rscript_exe, rscript, logfile)

  # Drive Register-ScheduledTask from PowerShell: unlike schtasks it takes the
  # working directory natively (-WorkingDirectory) and quotes the action args
  # itself, so we avoid a second layer of cmd-quoting. Single-quoted PS literals;
  # any embedded single quotes are doubled per PS escaping.
  ps_lit <- function(x) paste0("'", gsub("'", "''", x), "'")
  ps <- sprintf(paste(
    "$a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument %s -WorkingDirectory %s;",
    "$t = New-ScheduledTaskTrigger -%s -At %s;",
    "$s = New-ScheduledTaskSettingsSet -StartWhenAvailable;",
    "Register-ScheduledTask -TaskName %s -Action $a -Trigger $t -Settings $s -Force | Out-Null"),
    ps_lit(cmd_args), ps_lit(workdir), schedule, ps_lit(starttime), ps_lit(taskname))

  status <- system2("powershell",
                    c("-NoProfile", "-NonInteractive", "-Command", shQuote(ps)),
                    stdout = TRUE, stderr = TRUE)
  if (!is.null(attr(status, "status")) && attr(status, "status") != 0) {
    stop(paste(status, collapse = "\n"))
  }
  invisible(taskname)
}

# --- Scheduled tasks ---------------------------------------------------------

schedule_rscript(
  taskname  = "macro_daily_data",
  rscript   = file.path(repo_root, "R", "run_daily.R"),
  starttime = "16:00"
)
