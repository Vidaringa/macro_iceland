# Schedule tasks

library(taskscheduleR)

taskscheduler_create(
  taskname  = "macro_daily_data",
  rscript   = "c:/Users/vidar/projects/macro_iceland/R/get_daily_data.R",
  schedule  = "DAILY",
  starttime = "16:00",
  startdate = format(Sys.Date(), "%Y/%m/%d")
)
