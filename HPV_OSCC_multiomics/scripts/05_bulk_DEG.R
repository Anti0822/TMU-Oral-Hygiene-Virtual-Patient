# ============================================================
# 05_bulk_DEG.R — 每個資料集內獨立的差異表現分析
#
# 參考組：HPV⁻（log2FC > 0 = HPV⁺ 較高）
# 分析層：primary（oral cavity OSCC）、secondary（OPSCC）、sensitivity（mixed HNSCC，site 納入模型）
# 比較：
#   pos_vs_neg；若資料集有 HPV-active/inactive 標註，再加
#   active_vs_neg、active_vs_inactive、inactive_vs_neg、active_vs_nonactive
# 模型：expression ~ HPV + [anatomic_site] + [smoking] + [sex] + [stage] + [batch]
#   共變項只有在該層 ≥90% 樣本有值、且每個 level ≥2 樣本時才納入；缺值樣本排除並記錄。
# 方法：microarray / 非 counts → limma（eBayes trend + robust）；raw counts → DESeq2（主要）＋ limma-voom（交叉確認）
# 輸出：完整 ranked table（非只有 DEG）：logFC、95% CI、SE、nominal P、FDR、方向、n、Hedges' g
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
source(file.path(.src(), "utils.R"))
require_pkgs(c("limma", "edgeR"))
suppressPackageStartupMessages({ library(limma); library(edgeR) })
has_deseq <- requireNamespace("DESeq2", quietly = TRUE)
has_ch <- requireNamespace("ComplexHeatmap", quietly = TRUE)
set_project_seed(); start_log("05_bulk_DEG")

PADJ <- CFG$deg$padj_cutoff; LFC <- CFG$deg$lfc_cutoff; MIN_N <- CFG$deg$min_group_n
CORE <- harmonize_symbols(CFG$core_genes)

args <- commandArgs(trailingOnly = TRUE)
files <- list.files(pdir("processed"), pattern = "_gene_expr\\.rds$", full.names = TRUE)
if (length(args)) files <- files[sub("_gene_expr\\.rds$", "", basename(files)) %in% args]
assert_that(length(files) > 0, "找不到前處理後資料（02_processed_data/*_gene_expr.rds）")

# ---------- 臨床共變項正規化 ----------
norm_covariates <- function(s) {
  s <- copy(s)
  sm <- tolower(s$smoking %||% NA)
  s[, smoking_bin := fcase(grepl("never|non|^no$|^0$|<\\s*10", sm), "never",
                           grepl("current|former|ever|yes|smoker|^1$|pack|>", sm), "ever", default = NA_character_)]
  sx <- tolower(s$sex %||% NA)
  s[, sex_bin := fcase(grepl("^f|female|woman", sx), "F", grepl("^m|male|man", sx), "M", default = NA_character_)]
  st <- toupper(s$stage %||% NA)
  s[, stage_bin := fcase(grepl("IV|\\b4|III|\\b3", st), "late", grepl("\\bI\\b|\\bII\\b|\\b1|\\b2|^I|^II", st), "early", default = NA_character_)]
  s
}

usable_cov <- function(s, v) {
  x <- s[[v]]; if (is.null(x)) return(FALSE)
  cmp <- mean(!is.na(x)) >= 0.9
  tb <- table(x); cmp && length(tb) >= 2 && all(tb >= 2)
}

define_groups <- function(s, comparison) {
  g <- s$hpv_group_detail
  switch(comparison,
         pos_vs_neg          = fcase(s$hpv_binary == "HPV_pos", "case", s$hpv_binary == "HPV_neg", "ref"),
         active_vs_neg       = fcase(g == "HPV_active", "case", g == "HPV_neg", "ref"),
         active_vs_inactive  = fcase(g == "HPV_active", "case", g == "HPV_inactive", "ref"),
         inactive_vs_neg     = fcase(g == "HPV_inactive", "case", g == "HPV_neg", "ref"),
         active_vs_nonactive = fcase(g == "HPV_active", "case", g %in% c("HPV_inactive", "HPV_neg"), "ref"),
         # Level D（僅 p16）資料集：獨立的 surrogate 比較，結果不與 DNA/RNA-based pos_vs_neg 合併
         p16_surrogate_pos_vs_neg = fcase(s$hpv_p16_surrogate == "HPV_pos", "case", s$hpv_p16_surrogate == "HPV_neg", "ref"))
}

hedges_g <- function(expr, grp) {
  a <- expr[, grp == "case", drop = FALSE]; b <- expr[, grp == "ref", drop = FALSE]
  n1 <- ncol(a); n2 <- ncol(b)
  m1 <- rowMeans(a); m2 <- rowMeans(b)
  v1 <- apply(a, 1, var); v2 <- apply(b, 1, var)
  sp <- sqrt(((n1 - 1) * v1 + (n2 - 1) * v2) / (n1 + n2 - 2))
  J <- 1 - 3 / (4 * (n1 + n2) - 9)
  g <- J * (m1 - m2) / sp
  data.table(gene = rownames(expr), mean_case = m1, sd_case = sqrt(v1), mean_ref = m2, sd_ref = sqrt(v2),
             hedges_g = g, var_g = (n1 + n2) / (n1 * n2) + g^2 / (2 * (n1 + n2)))
}

run_one <- function(obj, gse, layer, comparison) {
  s <- norm_covariates(obj$samples)
  if (!"qc_outlier" %in% names(s)) s[, qc_outlier := FALSE]
  s <- s[!(qc_outlier %in% TRUE)]
  lay_col <- c(primary = "include_primary_OSCC", secondary = "include_secondary_OPSCC",
               sensitivity = "include_sensitivity_HNSCC")[layer]
  s <- s[get(lay_col) %in% TRUE]
  s[, grp := define_groups(.SD, comparison)]
  s <- s[!is.na(grp)]
  n_case <- sum(s$grp == "case"); n_ref <- sum(s$grp == "ref")
  if (n_case < MIN_N || n_ref < MIN_N) {
    return(list(status = sprintf("SKIP (n case=%d, ref=%d < %d)", n_case, n_ref, MIN_N)))
  }
  covs <- c(if (layer == "sensitivity") "anatomic_site", "smoking_bin", "sex_bin", "stage_bin", "batch")
  covs <- covs[vapply(covs, function(v) usable_cov(s, v), logical(1))]
  if (length(covs)) {
    drop <- s[, !complete.cases(.SD), .SDcols = covs]
    for (g in s$gsm[drop]) log_exclusion(gse, g, paste0("共變項缺值（", paste(covs, collapse = ","), "）"), paste("05", layer, comparison))
    s <- s[!drop]
  }
  s[, grp := factor(grp, levels = c("ref", "case"))]
  # 若設計矩陣不滿秩或殘差自由度 < 3，逐一移除共變項
  repeat {
    fml <- as.formula(paste("~ grp", if (length(covs)) paste("+", paste(covs, collapse = " + ")) else ""))
    X <- model.matrix(fml, data = s)
    if (qr(X)$rank == ncol(X) && nrow(X) - ncol(X) >= 3) break
    if (!length(covs)) return(list(status = "SKIP (design not estimable)"))
    log_msg("[注意] 移除共變項 ", tail(covs, 1), "（設計不可估計）"); covs <- head(covs, -1)
  }
  expr <- obj$expr[, s$gsm, drop = FALSE]
  if (obj$data_type == "rnaseq_counts" && has_deseq) {
    cnt <- obj$counts[rownames(obj$dge), s$gsm, drop = FALSE]
    dds <- DESeq2::DESeqDataSetFromMatrix(cnt, colData = as.data.frame(s), design = fml)
    dds <- DESeq2::DESeq(dds, quiet = TRUE)
    r <- as.data.frame(DESeq2::results(dds, name = "grp_case_vs_ref", alpha = PADJ))
    tt <- data.table(gene = rownames(r), logFC = r$log2FoldChange, SE = r$lfcSE, stat = r$stat,
                     P.Value = r$pvalue, adj.P.Val = r$padj)
    tt[, `:=`(CI.L = logFC - 1.96 * SE, CI.R = logFC + 1.96 * SE)]
    method <- "DESeq2 (Wald)"
    # voom 交叉確認
    v <- voom(obj$dge[, s$gsm], X); vf <- eBayes(lmFit(v, X))
    vt <- topTable(vf, coef = "grpcase", number = Inf, sort.by = "none")
    tt[, voom_logFC := vt[gene, "logFC"]]; tt[, voom_P := vt[gene, "P.Value"]]
  } else {
    fit <- lmFit(expr, X); fit <- eBayes(fit, trend = TRUE, robust = TRUE)
    t0 <- topTable(fit, coef = "grpcase", number = Inf, sort.by = "none", confint = 0.95)
    tt <- data.table(gene = rownames(t0), logFC = t0$logFC, CI.L = t0$CI.L, CI.R = t0$CI.R,
                     SE = (fit$stdev.unscaled[, "grpcase"] * sqrt(fit$s2.post))[rownames(t0)],
                     stat = t0$t, P.Value = t0$P.Value, adj.P.Val = t0$adj.P.Val)
    method <- if (obj$data_type == "rnaseq_normalized_nonCounts") "limma-trend on log2(x+1) [非 raw counts]" else "limma (eBayes trend, robust)"
  }
  hg <- hedges_g(expr, as.character(s$grp))
  tt <- merge(tt, hg, by = "gene", all.x = TRUE)
  tt[, `:=`(dataset = gse, layer = layer, comparison = comparison, method = method,
            covariates = paste(covs, collapse = "+"), n_case = sum(s$grp == "case"), n_ref = sum(s$grp == "ref"),
            direction = fifelse(logFC > 0, "up_in_case", "down_in_case"))]
  tt[, is_DEG := !is.na(adj.P.Val) & adj.P.Val < PADJ & abs(logFC) >= LFC]
  setorder(tt, P.Value)
  list(status = "OK", table = tt, samples = s, expr = expr)
}

volcano <- function(tt, title) {
  d <- copy(tt)[!is.na(P.Value)]
  d[, cls := fcase(is_DEG & logFC > 0, "Up in HPV⁺/case", is_DEG & logFC < 0, "Down in HPV⁺/case", default = "NS")]
  lab <- d[gene %in% CORE | (is_DEG & rank(P.Value) <= 15)]
  p <- ggplot(d, aes(logFC, -log10(P.Value), color = cls)) + geom_point(size = 0.6, alpha = 0.6) +
    scale_color_manual(values = c("Up in HPV⁺/case" = "#C0392B", "Down in HPV⁺/case" = "#2E86C1", NS = "grey75")) +
    geom_vline(xintercept = c(-LFC, LFC), lty = 2, linewidth = 0.3) + labs(title = title, color = NULL) + theme_pub()
  if (requireNamespace("ggrepel", quietly = TRUE))
    p <- p + ggrepel::geom_text_repel(data = lab, aes(label = display_symbol(gene)), size = 2.6, color = "black", max.overlaps = 30)
  p
}

core_boxplot <- function(res, title) {
  genes <- intersect(CORE, rownames(res$expr))
  if (!length(genes)) return(NULL)
  d <- rbindlist(lapply(genes, function(g) data.table(gene = display_symbol(g), gsm = colnames(res$expr),
                                                      value = res$expr[g, ], grp = res$samples$grp)))
  st <- res$table[gene %in% genes, .(gene = display_symbol(gene), lab = sprintf("log2FC=%.2f\nP=%.2g FDR=%.2g", logFC, P.Value, adj.P.Val))]
  ggplot(d, aes(grp, value, fill = grp)) + geom_boxplot(outlier.shape = NA, alpha = 0.6) +
    geom_jitter(width = 0.15, size = 0.8) + facet_wrap(~gene, scales = "free_y", nrow = 1) +
    geom_text(data = st, aes(x = 1.5, y = Inf, label = lab), vjust = 1.1, size = 2.4, inherit.aes = FALSE) +
    scale_fill_manual(values = c(ref = "#2E86C1", case = "#C0392B")) +
    labs(title = title, x = NULL, y = "log2 expression") + theme_pub() + theme(legend.position = "none")
}

top_heatmap <- function(res, title, n = 50) {
  if (!has_ch) return(NULL)
  top <- head(res$table[is_DEG == TRUE][order(P.Value), gene], n)
  if (length(top) < 5) top <- head(res$table[order(P.Value), gene], n)
  m <- res$expr[top, , drop = FALSE]; m <- t(scale(t(m)))
  ha <- ComplexHeatmap::HeatmapAnnotation(group = as.character(res$samples$grp), site = res$samples$anatomic_site,
                                          HPV_level = res$samples$hpv_evidence_level,
                                          col = list(group = c(ref = "#2E86C1", case = "#C0392B")))
  ComplexHeatmap::Heatmap(m, name = "z", top_annotation = ha, show_column_names = FALSE,
                          row_names_gp = grid::gpar(fontsize = 6), column_title = title)
}

all_res <- list(); status_log <- list()
for (f in files) {
  gse <- sub("_gene_expr\\.rds$", "", basename(f)); obj <- readRDS(f)
  has_activity <- any(obj$samples$hpv_group_detail %in% c("HPV_active", "HPV_inactive"))
  has_p16 <- any(!is.na(obj$samples$hpv_p16_surrogate))
  comps <- c("pos_vs_neg", if (has_activity) c("active_vs_neg", "active_vs_inactive", "inactive_vs_neg", "active_vs_nonactive"),
             if (has_p16) "p16_surrogate_pos_vs_neg")
  for (layer in c("primary", "secondary", "sensitivity")) for (cmp in comps) {
    key <- paste(gse, layer, cmp, sep = "__")
    r <- tryCatch(run_one(obj, gse, layer, cmp), error = function(e) list(status = paste("ERROR:", conditionMessage(e))))
    status_log[[key]] <- data.table(dataset = gse, layer = layer, comparison = cmp, status = r$status,
                                    n_case = if (!is.null(r$table)) r$table$n_case[1] else NA,
                                    n_ref = if (!is.null(r$table)) r$table$n_ref[1] else NA,
                                    n_DEG_up = if (!is.null(r$table)) r$table[is_DEG & logFC > 0, .N] else NA,
                                    n_DEG_down = if (!is.null(r$table)) r$table[is_DEG & logFC < 0, .N] else NA)
    log_msg(key, "：", r$status)
    if (r$status != "OK") next
    all_res[[key]] <- r$table
    safe_fwrite(r$table, pp("bulk", "DEG_tables", paste0(key, "_full.csv")))
    safe_fwrite(r$table[is_DEG == TRUE], pp("bulk", "DEG_tables", paste0(key, "_DEG.csv")))
    fwrite(r$table[!is.na(stat), .(gene, stat)][order(-stat)], pp("bulk", "ranked_lists", paste0(key, ".rnk")), sep = "\t", col.names = FALSE)
    ttl <- sprintf("%s | %s | %s (n=%d vs %d)", gse, layer, cmp, r$table$n_case[1], r$table$n_ref[1])
    save_fig(volcano(r$table, ttl), paste0("Fig5_volcano_", key), 6, 5, subdir = "volcano")
    bp <- core_boxplot(r, ttl); if (!is.null(bp)) save_fig(bp, paste0("Fig7_coreBox_", key), 11, 3.4, subdir = "core_boxplot")
    hm <- top_heatmap(r, ttl); if (!is.null(hm)) save_fig(hm, paste0("Fig6_topDEG_heatmap_", key), 8, 8, subdir = "heatmap")
  }
}
st <- rbindlist(status_log)
safe_fwrite(st, pp("tables", "Table_S4_DEG_run_status.csv"))
if (length(all_res)) {
  core <- rbindlist(lapply(all_res, function(t) t[gene %in% CORE]), fill = TRUE)
  core[, gene_display := display_symbol(gene)]
  safe_fwrite(core[, .(dataset, layer, comparison, gene_display, logFC, CI.L, CI.R, SE, P.Value, adj.P.Val,
                       hedges_g, direction, n_case, n_ref, method, covariates)],
              pp("tables", "Table_3_core_genes_per_dataset.csv"))
}
finish_script("05_bulk_DEG")
