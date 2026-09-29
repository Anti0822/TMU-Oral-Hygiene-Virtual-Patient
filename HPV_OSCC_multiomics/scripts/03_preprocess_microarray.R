# ============================================================
# 03_preprocess_microarray.R — Microarray 前處理與 QC（每個資料集獨立）
#
# 流程：
#  1. 優先使用 raw data（Affymetrix CEL → RMA：background correction + quantile + log2 + summarization；
#     Illumina non-normalized → limma::neqc；Agilent single-channel TXT → limma::read.maimages + normexp + quantile）
#     無 raw data 時使用 series matrix：自動判斷是否需 log2（GEO2R 規則），再 quantile normalization。
#  2. Probe annotation（GPL fData 的 symbol 欄）→ 多 probe 合併（utils::collapse_probes，預設保留平均表現最高 probe）
#  3. QC：PCA、hierarchical clustering、sample-sample correlation outlier、batch（scan date）評估
#  4. 輸出 02_processed_data/<GSE>_gene_expr.rds 與樣本表
# 用法：Rscript scripts/03_preprocess_microarray.R GSE65858 GSE3292 ...
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
source(file.path(.src(), "utils.R"))
require_pkgs(c("Biobase", "limma"))
suppressPackageStartupMessages({ library(Biobase); library(limma) })
set_project_seed(); start_log("03_preprocess_microarray")

args <- commandArgs(trailingOnly = TRUE)
ids <- if (length(args)) args else
  unlist(lapply(CFG$datasets$bulk, function(x) if (x$type == "microarray") x$id))
ids <- c(ids, unlist(lapply(CFG$datasets$cellline, `[[`, "id")))

needs_log2 <- function(ex) {
  qx <- as.numeric(quantile(ex, c(0, 0.25, 0.5, 0.75, 0.99, 1), na.rm = TRUE))
  (qx[5] > 100) || (qx[6] - qx[1] > 50 && qx[2] > 0)
}

symbol_from_fdata <- function(fd) {
  cand <- grep("^(gene.?symbol|symbol|gene_symbol|ilmn_gene|gene_assignment)$", names(fd), ignore.case = TRUE, value = TRUE)
  if (!length(cand)) return(rep(NA_character_, nrow(fd)))
  s <- as.character(fd[[cand[1]]])
  if (grepl("assignment", cand[1], ignore.case = TRUE)) s <- trimws(sapply(strsplit(s, " // "), `[`, 2))
  s
}

try_raw_affy <- function(gse) {
  cels <- list.files(pdir("raw", gse), pattern = "\\.cel(\\.gz)?$", ignore.case = TRUE, full.names = TRUE, recursive = TRUE)
  tars <- list.files(pdir("raw", gse), pattern = "_RAW\\.tar$", full.names = TRUE)
  if (!length(cels) && length(tars)) { utils::untar(tars[1], exdir = pdir("raw", gse, "RAW")); return(try_raw_affy(gse)) }
  if (!length(cels)) return(NULL)
  log_msg(gse, "：偵測到 ", length(cels), " 個 CEL，使用 RMA")
  if (requireNamespace("affy", quietly = TRUE)) {
    ab <- tryCatch(affy::ReadAffy(filenames = cels), error = function(e) NULL)
    if (!is.null(ab)) {
      scan_dates <- tryCatch(affy::protocolData(ab)$ScanDate, error = function(e) NA)
      es <- affy::rma(ab)   # background + quantile + log2 + median polish
      colnames(es) <- sub("^(GSM\\d+).*", "\\1", colnames(es))
      attr(es, "scan_date") <- setNames(as.character(scan_dates), colnames(es))
      return(es)
    }
  }
  if (requireNamespace("oligo", quietly = TRUE)) {   # Gene 1.0 ST 等新平台
    raw <- oligo::read.celfiles(cels)
    es <- oligo::rma(raw, target = "core")
    colnames(es) <- sub("^(GSM\\d+).*", "\\1", colnames(es))
    return(es)
  }
  NULL
}

qc_plots <- function(mat, samp, gse) {
  pc <- prcomp(t(mat[order(-apply(mat, 1, var))[1:min(2000, nrow(mat))], ]), scale. = TRUE)
  ve <- round(100 * pc$sdev^2 / sum(pc$sdev^2), 1)
  df <- data.table(gsm = colnames(mat), PC1 = pc$x[, 1], PC2 = pc$x[, 2])
  df <- merge(df, samp[, .(gsm, hpv_group_detail, anatomic_site, batch)], by = "gsm", all.x = TRUE)
  p <- ggplot(df, aes(PC1, PC2, color = hpv_group_detail, shape = anatomic_site)) + geom_point(size = 2.4) +
    labs(title = paste(gse, "PCA (top 2000 variable genes)"), x = paste0("PC1 (", ve[1], "%)"), y = paste0("PC2 (", ve[2], "%)")) +
    theme_pub()
  save_fig(p, paste0(gse, "_QC_PCA"), 6.5, 5, subdir = "QC")
  cm <- cor(mat, method = "pearson")
  hc <- hclust(as.dist(1 - cm), method = "average")
  save_fig(function() plot(hc, main = paste(gse, "hierarchical clustering (1 - Pearson)"), cex = 0.5, xlab = ""),
           paste0(gse, "_QC_hclust"), 10, 5, subdir = "QC")
  # outlier：每個樣本與其他樣本的平均相關 < Q1 - 3*IQR，或 PC1/PC2 Mahalanobis 距離 p < 0.001
  mc <- (colSums(cm) - 1) / (ncol(cm) - 1)
  thr <- quantile(mc, 0.25) - 3 * IQR(mc)
  md <- mahalanobis(pc$x[, 1:2], colMeans(pc$x[, 1:2]), cov(pc$x[, 1:2]))
  out <- data.table(gsm = colnames(mat), mean_corr = mc, corr_outlier = mc < thr,
                    mahal_p = pchisq(md, 2, lower.tail = FALSE))
  out[, pca_outlier := mahal_p < 0.001]
  # batch：PC1–5 與 batch / HPV 之關聯（R²）
  bt <- rbindlist(lapply(1:min(5, ncol(pc$x)), function(k) {
    d <- merge(data.table(gsm = rownames(pc$x), pc = pc$x[, k]), samp[, .(gsm, batch, hpv_group_detail)], by = "gsm")
    r2 <- function(v) if (length(unique(na.omit(d[[v]]))) > 1) summary(lm(d$pc ~ factor(d[[v]])))$r.squared else NA
    data.table(PC = paste0("PC", k), var_explained = ve[k], R2_batch = r2("batch"), R2_HPV = r2("hpv_group_detail"))
  }))
  list(outliers = out, batch_assoc = bt)
}

for (gse in ids) {
  log_msg("---- ", gse, " ----")
  ok <- tryCatch({
    samp <- read_sample_map(gse)
    es_list <- readRDS(file.path(pdir("raw", gse), paste0(gse, "_eset_list.rds")))
    raw_es <- try_raw_affy(gse)
    if (!is.null(raw_es)) {
      mat <- exprs(raw_es); source_used <- "raw CEL + RMA"
      fd <- fData(es_list[[1]])
      sym <- symbol_from_fdata(fd)[match(rownames(mat), rownames(fd))]
      scan <- attr(raw_es, "scan_date")
    } else {
      # series matrix（多 platform 時各自處理後只取同一 platform；跨平台不可直接合併）
      if (length(es_list) > 1) log_msg("[注意] ", gse, " 含多個 platform：各 platform 分開存檔，不合併")
      e <- es_list[[which.max(sapply(es_list, ncol))]]
      mat <- exprs(e); fd <- fData(e); sym <- symbol_from_fdata(fd); scan <- NULL
      assert_that(nrow(mat) > 0, paste(gse, "series matrix 無表現值；若為 RNA-seq 請改用 04_preprocess_rnaseq.R"))
      if (needs_log2(mat)) { mat[mat <= 0] <- NA; mat <- log2(mat); log_msg(gse, "：套用 log2") }
      mat <- normalizeBetweenArrays(mat, method = "quantile")
      source_used <- "series matrix + log2 check + quantile"
    }
    # 樣本對齊：只保留稽核表中的 GSM
    common <- intersect(colnames(mat), samp$gsm)
    miss <- setdiff(samp$gsm, colnames(mat))
    for (g in miss) log_exclusion(gse, g, "表現矩陣中沒有此 GSM", "03_preprocess")
    mat <- mat[, common, drop = FALSE]; samp <- samp[match(common, gsm)]
    # 缺值過多的 probe 移除，其餘以 row median 補
    keep_p <- rowMeans(is.na(mat)) < 0.2
    mat <- mat[keep_p, , drop = FALSE]; sym <- sym[keep_p]
    if (anyNA(mat)) { idx <- which(is.na(mat), arr.ind = TRUE); mat[idx] <- apply(mat, 1, median, na.rm = TRUE)[idx[, 1]] }
    gmat <- collapse_probes(mat, sym, method = "max_mean")
    log_msg(gse, "：", nrow(mat), " probes → ", nrow(gmat), " genes；", ncol(gmat), " samples（", source_used, "）")

    samp[, batch := if (!is.null(scan)) substr(scan[gsm], 1, 10) else NA_character_]
    qc <- qc_plots(gmat, samp, gse)
    safe_fwrite(qc$outliers, pp("processed", "QC", paste0(gse, "_outliers.csv")))
    safe_fwrite(qc$batch_assoc, pp("processed", "QC", paste0(gse, "_batch_PC_association.csv")))
    flagged <- qc$outliers[corr_outlier & pca_outlier, gsm]
    # 只在兩種準則同時成立時排除，並記錄；單一準則只標記
    for (g in flagged) log_exclusion(gse, g, "QC outlier（correlation 與 PCA 同時異常）", "03_preprocess")
    samp[, qc_outlier := gsm %in% flagged]

    if (requireNamespace("arrayQualityMetrics", quietly = TRUE) && !is.null(raw_es)) {
      try(arrayQualityMetrics::arrayQualityMetrics(raw_es, outdir = pp("processed", "QC", paste0(gse, "_AQM")), force = TRUE), silent = TRUE)
    }
    saveRDS(list(expr = gmat, samples = samp, data_type = "microarray_log2", source = source_used),
            pp("processed", paste0(gse, "_gene_expr.rds")))
    TRUE
  }, error = function(e) { log_msg("[錯誤] ", gse, "：", conditionMessage(e)); FALSE })
}
finish_script("03_preprocess_microarray")
