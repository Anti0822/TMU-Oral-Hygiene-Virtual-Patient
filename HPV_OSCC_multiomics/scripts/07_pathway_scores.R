# ============================================================
# 07_pathway_scores.R — Sample-level pathway scores、OGT/OGA balance、核心基因共表現
#
#  * Signature 定義：00_metadata/gene_signatures.csv（每個基因組成與來源皆列出）
#    另加 MSigDB Hallmark（msigdbr，若可用）作為獨立參照。
#  * 計分：GSVA（主要）與 ssGSEA（交叉確認）；singscore 若已安裝亦輸出。
#  * OGT−OGA（log2 差 = log2 ratio）僅為探索性「mRNA balance」，不可等同 global O-GlcNAc 蛋白量。
#  * 以 limma 比較各 layer / comparison 的 score（模型與 05 相同：sensitivity 納入 site）。
#  * 共表現：MTHFD2–OGT–OGA–CD274–CORO1A Spearman 相關，分 HPV⁺/HPV⁻ 分層；
#    跨資料集以 Fisher z random-effects 整合（Q4）。相關不代表調控。
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
source(file.path(.src(), "utils.R"))
require_pkgs(c("GSVA", "limma"))
suppressPackageStartupMessages({ library(GSVA); library(limma) })
set_project_seed(); start_log("07_pathway_scores")
CORE <- harmonize_symbols(CFG$core_genes)

sig <- fread(pp("metadata", "gene_signatures.csv"))
sig[, gene := harmonize_symbols(gene)]
gsets <- split(sig$gene, sig$signature)
if (requireNamespace("msigdbr", quietly = TRUE)) {
  h <- tryCatch(msigdbr::msigdbr(species = "Homo sapiens", category = "H"), error = function(e) NULL)
  if (!is.null(h)) gsets <- c(gsets, split(harmonize_symbols(h$gene_symbol), h$gs_name))
}

score_gsva <- function(expr, sets, method = c("gsva", "ssgsea")) {
  method <- match.arg(method)
  sets <- lapply(sets, intersect, rownames(expr)); sets <- sets[lengths(sets) >= 2]
  if (exists("gsvaParam", asNamespace("GSVA"))) {
    par <- if (method == "gsva") GSVA::gsvaParam(expr, sets, minSize = 2, kcdf = "Gaussian")
           else GSVA::ssgseaParam(expr, sets, minSize = 2)
    GSVA::gsva(par, verbose = FALSE)
  } else GSVA::gsva(expr, sets, method = method, min.sz = 2, kcdf = "Gaussian", verbose = FALSE)
}

files <- list.files(pdir("processed"), pattern = "_gene_expr\\.rds$", full.names = TRUE)
assert_that(length(files) > 0, "找不到前處理後資料")
score_tests <- list(); cor_rows <- list()
for (f in files) {
  gse <- sub("_gene_expr\\.rds$", "", basename(f)); obj <- readRDS(f)
  expr <- if (!is.null(obj$expr_unfiltered)) obj$expr_unfiltered else obj$expr
  s <- obj$samples[!(qc_outlier %in% TRUE) & sample_type == "tumor"]
  expr <- expr[, intersect(colnames(expr), s$gsm), drop = FALSE]; s <- s[match(colnames(expr), gsm)]
  if (ncol(expr) < 6) { log_msg(gse, "：tumor 樣本 < 6，略過"); next }
  sc_gsva <- score_gsva(expr, gsets, "gsva"); sc_ss <- score_gsva(expr, gsets, "ssgsea")
  bal <- if (all(c("OGT", "OGA") %in% rownames(expr))) expr["OGT", ] - expr["OGA", ] else NULL
  if (!is.null(bal)) sc_gsva <- rbind(sc_gsva, OGT_minus_OGA_log2ratio = bal)
  saveRDS(list(gsva = sc_gsva, ssgsea = sc_ss, samples = s), pp("pathway", paste0(gse, "_scores.rds")))
  safe_fwrite(as.data.table(t(sc_gsva), keep.rownames = "gsm"), pp("pathway", paste0(gse, "_GSVA_scores.csv")))

  # 以 limma 比較 score（layer × comparison）
  has_activity <- any(s$hpv_group_detail %in% c("HPV_active", "HPV_inactive"))
  comps <- c("pos_vs_neg", if (has_activity) c("active_vs_neg", "active_vs_inactive", "inactive_vs_neg"))
  for (layer in c("primary", "secondary", "sensitivity")) for (cmp in comps) {
    lay_col <- c(primary = "include_primary_OSCC", secondary = "include_secondary_OPSCC", sensitivity = "include_sensitivity_HNSCC")[layer]
    ss <- copy(s)[get(lay_col) %in% TRUE]
    g <- ss$hpv_group_detail
    ss[, grp := switch(cmp, pos_vs_neg = fcase(hpv_binary == "HPV_pos", "case", hpv_binary == "HPV_neg", "ref"),
                       active_vs_neg = fcase(g == "HPV_active", "case", g == "HPV_neg", "ref"),
                       active_vs_inactive = fcase(g == "HPV_active", "case", g == "HPV_inactive", "ref"),
                       inactive_vs_neg = fcase(g == "HPV_inactive", "case", g == "HPV_neg", "ref"))]
    ss <- ss[!is.na(grp)]
    if (min(table(factor(ss$grp, c("case", "ref")))) < CFG$deg$min_group_n) next
    ss[, grp := factor(grp, c("ref", "case"))]
    X <- if (layer == "sensitivity" && length(unique(ss$anatomic_site)) > 1) model.matrix(~ grp + anatomic_site, ss) else model.matrix(~ grp, ss)
    if (qr(X)$rank < ncol(X)) X <- model.matrix(~ grp, ss)
    for (nm in c("gsva", "ssgsea")) {
      M <- if (nm == "gsva") sc_gsva[, ss$gsm] else sc_ss[, ss$gsm]
      fit <- eBayes(lmFit(M, X))
      tt <- topTable(fit, coef = "grpcase", number = Inf, confint = TRUE, sort.by = "none")
      score_tests[[paste(gse, layer, cmp, nm)]] <- data.table(dataset = gse, layer = layer, comparison = cmp, method = nm,
        signature = rownames(tt), delta = tt$logFC, CI.L = tt$CI.L, CI.R = tt$CI.R, t = tt$t, P = tt$P.Value,
        FDR = tt$adj.P.Val, n_case = sum(ss$grp == "case"), n_ref = sum(ss$grp == "ref"))
    }
  }
  # 核心基因共表現（HPV 分層）
  cg <- intersect(c(CORE, "MYC", "SLC2A1", "GFPT1", "SHMT2"), rownames(expr))
  for (hg in c("HPV_pos", "HPV_neg", "all")) {
    idx <- if (hg == "all") !is.na(s$hpv_binary) else s$hpv_binary %in% hg
    if (sum(idx) < 8) next
    cm <- cor(t(expr[cg, idx, drop = FALSE]), method = "spearman")
    pr <- t(combn(cg, 2))
    cor_rows[[paste(gse, hg)]] <- data.table(dataset = gse, hpv = hg, gene1 = pr[, 1], gene2 = pr[, 2],
                                             rho = cm[pr], n = sum(idx))
    if (hg == "all") {
      m2 <- cm; dimnames(m2) <- list(display_symbol(rownames(m2)), display_symbol(colnames(m2)))
      d <- as.data.table(as.table(m2)); setnames(d, c("g1", "g2", "rho"))
      save_fig(ggplot(d, aes(g1, g2, fill = rho)) + geom_tile() + geom_text(aes(label = sprintf("%.2f", rho)), size = 2.3) +
                 scale_fill_gradient2(low = "#2E86C1", high = "#C0392B", limits = c(-1, 1)) + labs(x = NULL, y = NULL, title = paste(gse, "core-gene Spearman (tumors)")) +
                 theme_pub() + theme(axis.text.x = element_text(angle = 45, hjust = 1)),
               paste0("Fig12_coreCor_", gse), 6.5, 5.5, subdir = "pathway")
    }
  }
  # 樣本層級 pathway heatmap
  if (requireNamespace("ComplexHeatmap", quietly = TRUE)) {
    rows <- intersect(c(names(split(sig$gene, sig$signature)), "OGT_minus_OGA_log2ratio"), rownames(sc_gsva))
    rows <- rows[!grepl("^Cell_", rows)]
    o <- order(s$hpv_group_detail, s$anatomic_site)
    ha <- ComplexHeatmap::HeatmapAnnotation(HPV = s$hpv_group_detail[o], site = s$anatomic_site[o], level = s$hpv_evidence_level[o])
    hm <- ComplexHeatmap::Heatmap(t(scale(t(sc_gsva[rows, o]))), name = "z(GSVA)", top_annotation = ha, cluster_columns = FALSE,
                                  show_column_names = FALSE, row_names_gp = grid::gpar(fontsize = 7), column_title = gse)
    save_fig(hm, paste0("Fig11_pathwayHeatmap_", gse), 9, 5.5, subdir = "pathway")
  }
}
st <- rbindlist(score_tests)
if (nrow(st)) {
  safe_fwrite(st, pp("tables", "Table_5_pathway_score_tests.csv"))
  d <- st[method == "gsva" & comparison == "pos_vs_neg" & !grepl("^HALLMARK|^Cell_", signature)]
  if (nrow(d)) save_fig(ggplot(d, aes(paste(dataset, layer, sep = "\n"), signature, fill = t)) + geom_tile() +
                          geom_text(aes(label = ifelse(FDR < 0.05, "*", "")), size = 4) +
                          scale_fill_gradient2(low = "#2E86C1", high = "#C0392B") +
                          labs(x = NULL, y = NULL, title = "Pathway score: HPV⁺ vs HPV⁻ (limma t; * FDR<0.05)") + theme_pub() +
                          theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 7)),
                        "Fig11b_pathway_score_tests_summary", 9, 6, subdir = "pathway")
}
cr <- rbindlist(cor_rows)
if (nrow(cr)) {
  cr[, `:=`(z = atanh(pmin(pmax(rho, -0.999), 0.999)), v = 1 / pmax(n - 3, 1))]
  meta <- cr[, {
    w <- 1 / v; fe <- sum(w * z) / sum(w); Q <- sum(w * (z - fe)^2); k <- .N
    tau2 <- if (k > 1) max(0, (Q - (k - 1)) / (sum(w) - sum(w^2) / sum(w))) else 0
    wr <- 1 / (v + tau2); est <- sum(wr * z) / sum(wr); se <- sqrt(1 / sum(wr))
    .(k = k, pooled_rho = tanh(est), CI.L = tanh(est - 1.96 * se), CI.R = tanh(est + 1.96 * se),
      P = 2 * pnorm(-abs(est / se)), I2 = if (Q > 0) max(0, (Q - (k - 1)) / Q) else 0)
  }, by = .(hpv, gene1, gene2)]
  meta[, FDR := p.adjust(P, "BH")]
  safe_fwrite(cr, pp("tables", "Table_S6_core_coexpression_per_dataset.csv"))
  safe_fwrite(meta, pp("tables", "Table_6_core_coexpression_meta.csv"))
}
finish_script("07_pathway_scores")
