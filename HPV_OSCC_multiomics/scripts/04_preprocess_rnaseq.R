# ============================================================
# 04_preprocess_rnaseq.R — Bulk RNA-seq 前處理（raw counts；每個資料集獨立）
#
#  * 讀取 supplementary 中的 count matrix（自動偵測；亦可由 00_metadata/rnaseq_count_files.csv 指定）
#    欄位：dataset, file, gene_id_col, sample_id_regex（把欄名轉為 GSM 的規則；可留空）
#  * 若只有 FPKM/TPM（非整數），標示 is_counts = FALSE → 下游改用 limma-trend on log2(x+1)，
#    並在結果中註明「非 raw counts，效應量僅供參考」。不可對 raw counts 做 t-test。
#  * 若有 transcript-level（salmon/kallisto）檔案，用 tximport 彙整至 gene level。
#  * Ensembl → symbol（org.Hs.eg.db）；重複 symbol 保留總 counts 最高者。
#  * filterByExpr + TMM；輸出 DGEList 與 logCPM；PCA QC。
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
source(file.path(.src(), "utils.R"))
require_pkgs(c("edgeR", "limma"))
suppressPackageStartupMessages({ library(edgeR); library(limma) })
set_project_seed(); start_log("04_preprocess_rnaseq")

args <- commandArgs(trailingOnly = TRUE)
ids <- if (length(args)) args else
  unlist(lapply(CFG$datasets$bulk, function(x) if (x$type == "rnaseq_counts") x$id))

spec_f <- pp("metadata", "rnaseq_count_files.csv")
spec <- if (file.exists(spec_f)) fread(spec_f) else data.table(dataset = character(), file = character(),
                                                                  gene_id_col = character(), sample_id_regex = character())

find_count_file <- function(gse) {
  s <- spec[dataset == gse]
  if (nrow(s) && file.exists(file.path(PROJ, s$file[1]))) return(list(file = file.path(PROJ, s$file[1]), spec = s[1]))
  fs <- list.files(pdir("raw", gse), pattern = "(count|raw|expr|fpkm|tpm|matrix).*\\.(txt|tsv|csv)(\\.gz)?$",
                   ignore.case = TRUE, full.names = TRUE, recursive = TRUE)
  if (!length(fs)) return(NULL)
  list(file = fs[which.max(file.size(fs))], spec = NULL)
}

map_ids_to_symbol <- function(ids) {
  ids0 <- sub("\\.\\d+$", "", ids)
  if (mean(grepl("^ENSG", ids0)) > 0.5 && requireNamespace("org.Hs.eg.db", quietly = TRUE)) {
    sym <- AnnotationDbi::mapIds(org.Hs.eg.db::org.Hs.eg.db, ids0, "SYMBOL", "ENSEMBL", multiVals = "first")
    return(unname(sym))
  }
  if (mean(grepl("^\\d+$", ids0)) > 0.5 && requireNamespace("org.Hs.eg.db", quietly = TRUE)) {
    return(unname(AnnotationDbi::mapIds(org.Hs.eg.db::org.Hs.eg.db, ids0, "SYMBOL", "ENTREZID", multiVals = "first")))
  }
  sub("\\|.*$", "", ids)   # 例如 "CD274|29126" (TCGA 格式)
}

for (gse in ids) {
  log_msg("---- ", gse, " ----")
  tryCatch({
    samp <- read_sample_map(gse)
    cf <- find_count_file(gse)
    assert_that(!is.null(cf), paste0(gse, "：找不到 count matrix；請執行 01_download_geo.R --raw 並在 rnaseq_count_files.csv 指定檔案"))
    log_msg("讀取 ", cf$file)
    raw <- fread(cf$file)
    idcol <- if (!is.null(cf$spec) && nzchar(cf$spec$gene_id_col)) cf$spec$gene_id_col else names(raw)[1]
    ids_g <- as.character(raw[[idcol]]); raw[, (idcol) := NULL]
    num <- raw[, which(sapply(raw, is.numeric)), with = FALSE]
    cnt <- as.matrix(num); rownames(cnt) <- ids_g
    # 欄名 → GSM：優先 spec regex；否則以 title 對應
    cn <- colnames(cnt)
    if (!is.null(cf$spec) && nzchar(cf$spec$sample_id_regex)) cn <- sub(cf$spec$sample_id_regex, "\\1", cn)
    if (!all(grepl("^GSM", cn))) {
      m <- match(cn, samp$title); cn[!is.na(m)] <- samp$gsm[m[!is.na(m)]]
    }
    colnames(cnt) <- cn
    unmatched <- setdiff(colnames(cnt), samp$gsm)
    if (length(unmatched)) log_msg("[警告] ", length(unmatched), " 個欄名無法對應 GSM：", paste(head(unmatched), collapse = ","))
    common <- intersect(colnames(cnt), samp$gsm)
    for (g in setdiff(samp$gsm, common)) log_exclusion(gse, g, "count matrix 中沒有此 GSM", "04_preprocess")
    assert_that(length(common) >= 4, paste(gse, "可對應的樣本 < 4"))
    cnt <- cnt[, common, drop = FALSE]; samp <- samp[match(common, gsm)]

    is_counts <- all(abs(cnt - round(cnt)) < 1e-6, na.rm = TRUE)
    if (!is_counts) log_msg("[注意] ", gse, " 不是整數 counts（可能為 FPKM/TPM）→ 下游使用 limma-trend on log2(x+1)")

    sym <- harmonize_symbols(map_ids_to_symbol(rownames(cnt)))
    keep <- !is.na(sym) & sym != ""
    cnt <- cnt[keep, ]; sym <- sym[keep]
    tot <- rowSums(cnt); o <- order(sym, -tot); first <- !duplicated(sym[o])
    cnt <- cnt[o[first], ]; rownames(cnt) <- sym[o[first]]

    samp[, `:=`(batch = NA_character_, qc_outlier = FALSE)]
    if (is_counts) {
      y <- DGEList(round(cnt))
      grp <- factor(samp$hpv_group_detail)
      k <- filterByExpr(y, group = grp)
      y <- y[k, , keep.lib.sizes = FALSE]; y <- calcNormFactors(y, method = "TMM")
      logcpm <- cpm(y, log = TRUE, prior.count = 2)
      core_lost <- setdiff(harmonize_symbols(CFG$core_genes), rownames(y))
      if (length(core_lost)) log_msg("[注意] 核心基因經 filterByExpr 後被濾除（低表現）：", paste(core_lost, collapse = ","),
                                     "；於 core-gene 分析中另以未過濾矩陣呈現")
      out <- list(counts = round(cnt), dge = y, expr = logcpm, samples = samp, data_type = "rnaseq_counts",
                  expr_unfiltered = cpm(DGEList(round(cnt)), log = TRUE, prior.count = 2))
    } else {
      logx <- log2(cnt + 1); logx <- logx[rowMeans(logx > 1) > 0.2, ]
      out <- list(expr = logx, samples = samp, data_type = "rnaseq_normalized_nonCounts")
    }
    pc <- prcomp(t(out$expr[order(-apply(out$expr, 1, var))[1:min(2000, nrow(out$expr))], ]), scale. = TRUE)
    df <- data.table(gsm = colnames(out$expr), PC1 = pc$x[, 1], PC2 = pc$x[, 2], samp[, .(hpv_group_detail, anatomic_site)])
    save_fig(ggplot(df, aes(PC1, PC2, color = hpv_group_detail, shape = anatomic_site)) + geom_point(size = 2.4) +
               labs(title = paste(gse, "PCA (logCPM)")) + theme_pub(), paste0(gse, "_QC_PCA"), 6.5, 5, subdir = "QC")
    saveRDS(out, pp("processed", paste0(gse, "_gene_expr.rds")))
    log_msg(gse, "：", nrow(out$expr), " genes × ", ncol(out$expr), " samples；is_counts = ", is_counts)
  }, error = function(e) log_msg("[錯誤] ", gse, "：", conditionMessage(e)))
}
finish_script("04_preprocess_rnaseq")
