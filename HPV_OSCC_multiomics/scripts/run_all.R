# ============================================================
# run_all.R — 依序執行整個流程（需可連線 NCBI GEO / UCSC Xena）
#
# 流程設計刻意分兩段：
#   Stage 1（稽核）：01 下載 → 02 GSM 稽核 → 人工確認 *_samples_curated.csv → 停止
#   Stage 2（分析）：確認完成後以 --analysis 執行 03–13
# 用法：
#   Rscript scripts/run_all.R            # Stage 1
#   Rscript scripts/run_all.R --analysis # Stage 2
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
SCRIPTS <- .src(); source(file.path(SCRIPTS, "utils.R"))
args <- commandArgs(trailingOnly = TRUE)
run <- function(script, a = character()) {
  cmd <- paste("Rscript", shQuote(file.path(SCRIPTS, script)), paste(a, collapse = " "))
  message("\n>>> ", cmd); st <- system(cmd)
  if (st != 0) stop(script, " 失敗；請查看 results/logs/")
}
if (!"--analysis" %in% args) {
  run("01_download_geo.R", "--raw")
  run("02_gsm_sample_audit.R")
  message("\nStage 1 完成。請：\n",
          " 1) 檢視 00_metadata/gsm_mapping/*_characteristics_inventory.csv 與 *_samples_auto.csv\n",
          " 2) 依原始論文補正後另存為 *_samples_curated.csv（尤其 tongue_ambiguous、Level E、site unknown）\n",
          " 3) 必要時編輯 00_metadata/hpv_field_overrides.csv 並重跑 02\n",
          " 4) 更新 00_metadata/dataset_audit_table.csv 的「尚待確認」欄位\n",
          "然後執行：Rscript scripts/run_all.R --analysis")
} else {
  arr <- unlist(lapply(CFG$datasets$bulk, function(x) if (x$type == "microarray") x$id))
  rs  <- unlist(lapply(CFG$datasets$bulk, function(x) if (x$type == "rnaseq_counts") x$id))
  run("03_preprocess_microarray.R", arr)
  run("04_preprocess_rnaseq.R", rs)
  for (s in c("05_bulk_DEG.R", "06_meta_analysis.R", "07_pathway_scores.R", "08_enrichment_network.R",
              "09_immune_deconvolution.R")) run(s)
  sc <- tryCatch(run("10_single_cell.R", c("GSE164690", "--max-cells-per-sample", "5000")), error = function(e) message("[single-cell 略過] ", conditionMessage(e)))
  for (s in c("11_survival.R", "12_candidate_priority.R", "13_summary_figures.R")) run(s)
  message("\n全部完成：圖在 09_figures/，表在 10_tables/，log 與 sessionInfo 在 results/")
}
