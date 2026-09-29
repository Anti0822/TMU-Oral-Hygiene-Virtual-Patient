# ============================================================
# 01_download_geo.R — 下載 GEO series matrix、phenoData 與（選擇性）原始檔
# 輸出：
#   01_raw_data/<GSE>/<GSE>_eset_list.rds       ExpressionSet list（每個 platform 一個）
#   01_raw_data/<GSE>/<GSE>_pheno_raw.csv       未修改的 GSM phenoData
#   00_metadata/geo_series_summary_auto.csv     series 層級資訊（title、PMID、platform、N、補充檔）
# 用法：Rscript scripts/01_download_geo.R [--raw] [GSE ...]
#   --raw  同時下載 supplementary files（CEL/TXT/counts；檔案可能很大）
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
source(file.path(.src(), "utils.R"))
require_pkgs(c("GEOquery", "Biobase"))
suppressPackageStartupMessages({ library(GEOquery); library(Biobase) })
set_project_seed(); start_log("01_download_geo")
options(timeout = 3600)

args <- commandArgs(trailingOnly = TRUE)
get_raw <- "--raw" %in% args
ids <- setdiff(args, "--raw")
if (!length(ids)) {
  ids <- unique(c(sapply(CFG$datasets$bulk, `[[`, "id"),
                  sapply(CFG$datasets$singlecell, `[[`, "id"),
                  sapply(CFG$datasets$cellline, `[[`, "id")))
}

series_summary <- list()
for (gse in ids) {
  out_dir <- pdir("raw", gse)
  log_msg("---- ", gse, " ----")
  res <- tryCatch({
    esets <- getGEO(gse, GSEMatrix = TRUE, getGPL = TRUE, destdir = out_dir, AnnotGPL = FALSE)
    saveRDS(esets, file.path(out_dir, paste0(gse, "_eset_list.rds")))
    pheno <- rbindlist(lapply(names(esets), function(nm) {
      pd <- as.data.table(pData(esets[[nm]]), keep.rownames = "gsm_rowname")
      pd[, series_matrix_file := nm]
      pd
    }), fill = TRUE)
    fwrite(pheno, file.path(out_dir, paste0(gse, "_pheno_raw.csv")))

    # series-level 資訊
    e1 <- esets[[1]]
    ex <- experimentData(e1)
    platforms <- unique(unlist(lapply(esets, annotation)))
    n_feat <- paste(sapply(esets, nrow), collapse = ";")
    supp <- tryCatch(GEOquery::getGEOSuppFiles(gse, makeDirectory = FALSE, baseDir = out_dir,
                                               fetch_files = FALSE), error = function(e) NULL)
    supp_names <- if (!is.null(supp)) paste(supp$fname, collapse = "; ") else "無法取得清單"
    if (get_raw && !is.null(supp)) {
      GEOquery::getGEOSuppFiles(gse, makeDirectory = FALSE, baseDir = out_dir)
    }
    data.table(gse = gse, title = ex@title,
               pubmed_id_series = paste(na.omit(ex@pubMedIds), collapse = ";"),
               platform = paste(platforms, collapse = ";"),
               n_samples_total = nrow(pheno), n_features = n_feat,
               submission_date = paste(unique(pheno$submission_date), collapse = ";"),
               supplementary_files = supp_names,
               series_matrix_has_expression = all(sapply(esets, nrow) > 0),
               download_status = "OK")
  }, error = function(e) {
    log_msg("[錯誤] ", gse, " 下載失敗：", conditionMessage(e))
    data.table(gse = gse, download_status = paste("FAILED:", conditionMessage(e)))
  })
  series_summary[[gse]] <- res
}
summ <- rbindlist(series_summary, fill = TRUE)
safe_fwrite(summ, pp("metadata", "geo_series_summary_auto.csv"))
assert_that(any(summ$download_status == "OK"), "所有資料集均下載失敗：請檢查網路是否可連到 ncbi.nlm.nih.gov")
finish_script("01_download_geo")
