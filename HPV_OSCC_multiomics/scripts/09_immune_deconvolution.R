# ============================================================
# 09_immune_deconvolution.R — Bulk 免疫微環境估計（≥2 種方法交叉驗證）與 purity-adjusted 相關
#
#  方法優先序（自動偵測已安裝者）：
#   immunedeconv：mcp_counter、epic、quantiseq、xcell、estimate
#   否則：MCPcounter 套件 + estimate 套件
#   最後 fallback：GSVA on canonical marker sets（00_metadata/gene_signatures.csv 的 Cell_*），
#                  並以 1 − scaled(immune+stromal) 作為「purity proxy」（僅供 sensitivity 使用，需明確標註）
#  注意：
#   * EPIC / quanTIseq 需 non-log TPM 尺度；microarray 以 2^log2 近似，結果只作相對比較。
#   * CORO1A 與 CD274 在 bulk 中可能主要來自免疫細胞 → 以 tumor purity 做 partial correlation；
#     即使調整後仍相關，也不能解釋為腫瘤細胞內在機制（需 07_single_cell 佐證）。
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
source(file.path(.src(), "utils.R"))
require_pkgs(c("GSVA", "limma")); suppressPackageStartupMessages({ library(GSVA); library(limma) })
set_project_seed(); start_log("09_immune_deconvolution")
has <- function(p) requireNamespace(p, quietly = TRUE)
CORE <- harmonize_symbols(CFG$core_genes)
KEY_CELLS <- c("CD8", "NK", "Treg|regulatory", "B cell|B_", "Plasma", "Macrophage|Monocyte", "Dendritic|DC", "Fibroblast|CAF",
               "Immune|immune score", "Stromal|stromal score", "purity")

partial_spearman <- function(x, y, z) {   # 以 rank residual 計算 partial Spearman
  ok <- complete.cases(x, y, z); if (sum(ok) < 8) return(c(rho = NA, P = NA))
  rx <- resid(lm(rank(x[ok]) ~ rank(z[ok]))); ry <- resid(lm(rank(y[ok]) ~ rank(z[ok])))
  ct <- cor.test(rx, ry); n <- sum(ok)
  tt <- ct$estimate * sqrt((n - 3) / (1 - ct$estimate^2))   # df 扣除 1 個控制變項
  c(rho = unname(ct$estimate), P = unname(2 * pt(-abs(tt), n - 3)))
}

deconvolve <- function(expr, is_log = TRUE) {
  lin <- if (is_log) 2^expr else expr
  out <- list()
  if (has("immunedeconv")) {
    for (m in c("mcp_counter", "epic", "quantiseq", "xcell", "estimate")) {
      r <- tryCatch(immunedeconv::deconvolute(lin, m), error = function(e) { log_msg("[immunedeconv] ", m, " 失敗：", conditionMessage(e)); NULL })
      if (!is.null(r)) { r <- as.data.table(r); out[[m]] <- melt(r, id.vars = "cell_type", variable.name = "gsm", value.name = "score")[, method := m] }
    }
  }
  if (!"mcp_counter" %in% names(out) && has("MCPcounter")) {
    r <- MCPcounter::MCPcounter.estimate(expr, featuresType = "HUGO_symbols")
    out$mcp_counter <- melt(as.data.table(r, keep.rownames = "cell_type"), id.vars = "cell_type", variable.name = "gsm", value.name = "score")[, method := "MCPcounter"]
  }
  if (!"estimate" %in% names(out) && has("estimate")) {
    tf <- tempfile(fileext = ".gct"); inp <- tempfile(); fo <- tempfile()
    write.table(data.frame(NAME = rownames(expr), expr, check.names = FALSE), inp, sep = "\t", quote = FALSE, row.names = FALSE)
    estimate::filterCommonGenes(inp, tf, id = "GeneSymbol"); estimate::estimateScore(tf, fo, platform = "affymetrix")
    e <- read.table(fo, skip = 2, header = TRUE, sep = "\t", check.names = FALSE)
    out$estimate <- melt(as.data.table(e[, -2])[, cell_type := e$NAME][, NAME := NULL], id.vars = "cell_type", variable.name = "gsm", value.name = "score")[, method := "estimate"]
  }
  # fallback／額外：GSVA marker-based（永遠計算，作為第二種獨立方法）
  sig <- fread(pp("metadata", "gene_signatures.csv"))[grepl("^Cell_", signature)]
  gs <- lapply(split(harmonize_symbols(sig$gene), sig$signature), intersect, rownames(expr)); gs <- gs[lengths(gs) >= 2]
  sc <- GSVA::gsva(GSVA::gsvaParam(expr, gs, minSize = 2), verbose = FALSE)
  d <- melt(as.data.table(sc, keep.rownames = "cell_type"), id.vars = "cell_type", variable.name = "gsm", value.name = "score")[, method := "GSVA_markers"]
  imm <- colMeans(sc[intersect(rownames(sc), c("Cell_T", "Cell_B", "Cell_NK", "Cell_Macrophage", "Cell_DC", "Cell_Plasma")), , drop = FALSE])
  str <- colMeans(sc[intersect(rownames(sc), c("Cell_CAF", "Cell_Endothelial")), , drop = FALSE])
  proxy <- 1 - scales::rescale(imm + str)
  d <- rbind(d, data.table(cell_type = "purity_proxy (1 - scaled immune+stromal GSVA)", gsm = names(proxy), score = proxy, method = "GSVA_markers"))
  out$GSVA_markers <- d
  res <- rbindlist(out, fill = TRUE); res[, gsm := as.character(gsm)]; res
}

files <- list.files(pdir("processed"), "_gene_expr\\.rds$", full.names = TRUE)
comp_all <- list(); pc_all <- list()
for (f in files) {
  gse <- sub("_gene_expr\\.rds$", "", basename(f)); obj <- readRDS(f)
  s <- obj$samples[sample_type == "tumor" & !is.na(hpv_binary) & !(qc_outlier %in% TRUE)]
  if (nrow(s) < 8) { log_msg(gse, "：tumor n < 8，略過"); next }
  expr <- (if (!is.null(obj$expr_unfiltered)) obj$expr_unfiltered else obj$expr)[, s$gsm]
  dc <- tryCatch(deconvolve(expr, TRUE), error = function(e) { log_msg("[錯誤] ", gse, "：", conditionMessage(e)); NULL })
  if (is.null(dc)) next
  dc <- merge(dc, s[, .(gsm, hpv_binary, hpv_group_detail, anatomic_site)], by = "gsm")
  safe_fwrite(dc, pp("immune", paste0(gse, "_deconvolution_long.csv")))

  # HPV⁺ vs HPV⁻（Wilcoxon + limma 調整 site）；分 layer
  for (layer in c("oral_cavity", "oropharynx", "all_sites")) {
    dd <- if (layer == "all_sites") dc else dc[anatomic_site == layer]
    if (dd[, uniqueN(gsm[hpv_binary == "HPV_pos"])] < 3 || dd[, uniqueN(gsm[hpv_binary == "HPV_neg"])] < 3) next
    r <- dd[, {
      w <- suppressWarnings(wilcox.test(score[hpv_binary == "HPV_pos"], score[hpv_binary == "HPV_neg"]))
      adj_p <- if (layer == "all_sites" && uniqueN(anatomic_site) > 1) tryCatch(coef(summary(lm(score ~ hpv_binary + anatomic_site)))[2, 4], error = function(e) NA) else NA
      .(median_pos = median(score[hpv_binary == "HPV_pos"]), median_neg = median(score[hpv_binary == "HPV_neg"]),
        wilcox_P = w$p.value, site_adj_P = adj_p, n_pos = sum(hpv_binary == "HPV_pos"), n_neg = sum(hpv_binary == "HPV_neg"))
    }, by = .(method, cell_type)]
    r[, `:=`(dataset = gse, layer = layer, FDR = p.adjust(wilcox_P, "BH")), by = method]
    comp_all[[paste(gse, layer)]] <- r
  }
  key <- dc[grepl(paste(KEY_CELLS, collapse = "|"), cell_type, ignore.case = TRUE)]
  if (nrow(key)) save_fig(ggplot(key, aes(hpv_binary, score, fill = hpv_binary)) + geom_boxplot(outlier.shape = NA, alpha = 0.6) +
                            geom_jitter(width = 0.15, size = 0.4) + facet_wrap(~ method + cell_type, scales = "free_y", ncol = 6) +
                            scale_fill_manual(values = HPV_COLORS) + labs(title = paste(gse, "immune/stromal estimates"), x = NULL) +
                            theme_pub(8) + theme(legend.position = "none", strip.text = element_text(size = 5.5)),
                          paste0("Fig13_immune_", gse), 13, 10, subdir = "immune")

  # purity-adjusted correlation：核心基因 × 免疫細胞
  pur <- dc[grepl("purity", cell_type, ignore.case = TRUE)]
  pur_src <- if (any(pur$method == "estimate")) "estimate" else "GSVA_markers"
  pur <- pur[method == pur_src][, .(gsm, purity = score)][!duplicated(gsm)]
  cells <- dc[!grepl("purity|score", cell_type, ignore.case = TRUE)]
  for (g in intersect(CORE, rownames(expr))) {
    ge <- data.table(gsm = colnames(expr), gexp = expr[g, ])
    z <- merge(merge(cells, ge, by = "gsm"), pur, by = "gsm")
    r <- z[, { raw <- suppressWarnings(cor.test(gexp, score, method = "spearman")); pc <- partial_spearman(gexp, score, purity)
               .(rho_raw = unname(raw$estimate), P_raw = raw$p.value, rho_partial = pc[["rho"]], P_partial = pc[["P"]], n = .N) },
           by = .(method, cell_type)][, hpv := "all"]
    r2 <- z[, { pc <- partial_spearman(gexp, score, purity); .(rho_partial = pc[["rho"]], P_partial = pc[["P"]], n = .N) },
            by = .(method, cell_type, hpv = hpv_binary)]
    pc_all[[paste(gse, g)]] <- rbind(r, r2, fill = TRUE)[, `:=`(dataset = gse, gene = display_symbol(g), purity_source = pur_src)]
  }
}
comp <- rbindlist(comp_all, fill = TRUE); if (nrow(comp)) safe_fwrite(comp, pp("tables", "Table_7_immune_HPV_comparison.csv"))
pc <- rbindlist(pc_all, fill = TRUE)
if (nrow(pc)) {
  pc[, FDR_partial := p.adjust(P_partial, "BH"), by = .(dataset, gene)]
  safe_fwrite(pc, pp("tables", "Table_8_core_gene_immune_partial_correlation.csv"))
  d <- pc[hpv == "all" & !is.na(rho_raw)]
  p <- ggplot(d, aes(rho_raw, rho_partial, color = method)) + geom_abline(lty = 2) + geom_hline(yintercept = 0, lwd = 0.2) +
    geom_vline(xintercept = 0, lwd = 0.2) + geom_point(size = 1.2) + facet_grid(dataset ~ gene) +
    labs(x = "Spearman ρ (unadjusted)", y = "partial ρ (tumor purity adjusted)",
         title = "Core genes vs immune/stromal estimates: effect of purity adjustment") + theme_pub(8)
  save_fig(p, "Fig14_purity_adjusted_correlation", 12, 2.5 + 2 * uniqueN(d$dataset), subdir = "immune")
}
finish_script("09_immune_deconvolution")
