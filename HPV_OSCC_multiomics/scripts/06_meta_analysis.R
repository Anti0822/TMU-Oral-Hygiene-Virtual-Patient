# ============================================================
# 06_meta_analysis.R — 跨資料集整合（不合併 raw expression）
#
#  每個 (layer, comparison) 分別整合 05 的 per-dataset 完整結果：
#   1. Direction consistency：各資料集 logFC 方向、nominal P<0.05 的同向次數
#   2. Random-effects meta-analysis
#      - 主要：Hedges' g（standardized mean difference，跨平台可比）以 DerSimonian–Laird 向量化計算（全基因）
#      - 核心基因：metafor::rma(REML) + Knapp–Hartung，輸出 forest plot 與 I²/τ²
#   3. Stouffer（signed, sqrt(n) 加權）與 Fisher（雙尾、方向無關，僅輔助）p-value combination
#   4. Robust Rank Aggregation（RobustRankAggreg；up 與 down 分開）
#   5. DEG list：HPV⁺ up / down；≥2 資料集重現；所有主要資料集共同；UpSet plot
#   6. Rank-rank comparison（t-statistic Spearman 相關 + RRHO 式 overlap heatmap）
#  輸出 FDR 皆為 BH。
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
source(file.path(.src(), "utils.R"))
set_project_seed(); start_log("06_meta_analysis")
has_metafor <- requireNamespace("metafor", quietly = TRUE)
has_rra <- requireNamespace("RobustRankAggreg", quietly = TRUE)
has_upset <- requireNamespace("UpSetR", quietly = TRUE)
CORE <- harmonize_symbols(CFG$core_genes)

files <- list.files(pp("bulk", "DEG_tables"), pattern = "_full\\.csv$", full.names = TRUE)
assert_that(length(files) > 0, "找不到 05_bulk_DEG 的結果")
all <- rbindlist(lapply(files, fread), fill = TRUE)

dl_meta <- function(y, v) {      # 向量化 DerSimonian–Laird（每列 = 一個 gene，每欄 = 一個 dataset）
  w <- 1 / v; k <- rowSums(!is.na(y))
  sw <- rowSums(w, na.rm = TRUE); fe <- rowSums(w * y, na.rm = TRUE) / sw
  Q <- rowSums(w * (y - fe)^2, na.rm = TRUE)
  C <- sw - rowSums(w^2, na.rm = TRUE) / sw
  tau2 <- pmax(0, (Q - (k - 1)) / C)
  wr <- 1 / (v + tau2); est <- rowSums(wr * y, na.rm = TRUE) / rowSums(wr, na.rm = TRUE)
  se <- sqrt(1 / rowSums(wr, na.rm = TRUE)); z <- est / se
  I2 <- ifelse(Q > 0, pmax(0, (Q - (k - 1)) / Q), 0)
  data.table(k = k, meta_g = est, meta_se = se, meta_CI.L = est - 1.96 * se, meta_CI.R = est + 1.96 * se,
             meta_z = z, meta_P = 2 * pnorm(-abs(z)), Q = Q, Q_P = pchisq(Q, pmax(k - 1, 1), lower.tail = FALSE),
             tau2 = tau2, I2 = I2)
}

rrho_plot <- function(t1, t2, n1, n2, step = 200) {
  g <- intersect(names(t1), names(t2)); r1 <- rank(-t1[g]); r2 <- rank(-t2[g]); N <- length(g)
  br <- seq(step, N, by = step)
  m <- outer(br, br, Vectorize(function(a, b) {
    k <- sum(r1 <= a & r2 <= b); -phyper(k - 1, a, N - a, b, lower.tail = FALSE, log.p = TRUE) / log(10)
  }))
  d <- data.table(expand.grid(rank_1 = br, rank_2 = br)); d[, log10P := as.vector(m)]
  ggplot(d, aes(rank_1, rank_2, fill = pmin(log10P, 50))) + geom_raster() +
    scale_fill_viridis_c(name = "-log10 P\n(overlap)") + labs(x = paste(n1, "rank (HPV⁺ up →)"), y = paste(n2, "rank")) +
    theme_pub()
}

for (lay in unique(all$layer)) for (cmp in unique(all$comparison)) {
  d <- all[layer == lay & comparison == cmp & !is.na(logFC)]
  ds <- unique(d$dataset); tag <- paste(lay, cmp, sep = "__")
  if (length(ds) < 2) { log_msg(tag, "：資料集數 < 2，不做 meta-analysis（僅保留 per-dataset 結果）"); next }
  log_msg("---- ", tag, "：", length(ds), " datasets (", paste(ds, collapse = ","), ") ----")

  wide <- function(col) { w <- dcast(d, gene ~ dataset, value.var = col); m <- as.matrix(w[, -1]); rownames(m) <- w$gene; m }
  G <- wide("hedges_g"); V <- wide("var_g"); L <- wide("logFC"); P <- wide("P.Value"); Q <- wide("adj.P.Val")
  N <- dcast(d, gene ~ dataset, value.var = "n_case")[, -1] + dcast(d, gene ~ dataset, value.var = "n_ref")[, -1]
  N <- as.matrix(N); rownames(N) <- rownames(G)

  # 1) direction consistency
  dirc <- data.table(gene = rownames(L), n_datasets = rowSums(!is.na(L)),
                     n_up = rowSums(L > 0, na.rm = TRUE), n_down = rowSums(L < 0, na.rm = TRUE),
                     n_up_nomP = rowSums(L > 0 & P < 0.05, na.rm = TRUE), n_down_nomP = rowSums(L < 0 & P < 0.05, na.rm = TRUE),
                     n_up_DEG = rowSums(L >= CFG$deg$lfc_cutoff & Q < CFG$deg$padj_cutoff, na.rm = TRUE),
                     n_down_DEG = rowSums(L <= -CFG$deg$lfc_cutoff & Q < CFG$deg$padj_cutoff, na.rm = TRUE))
  dirc[, direction_consistency := pmax(n_up, n_down) / n_datasets]
  # sign test：方向一致是否超過隨機
  dirc[, sign_test_P := mapply(function(u, n) if (n > 0) binom.test(u, n)$p.value else NA, pmax(n_up, n_down), n_datasets)]

  # 2) random effects on Hedges' g
  re <- dl_meta(G, V); re[, gene := rownames(G)]
  re_lfc <- { vv <- wide("SE")^2; x <- dl_meta(L, vv); x[, gene := rownames(L)]
              setnames(x, setdiff(names(x), "gene"), paste0("lfc_", setdiff(names(x), "gene"))); x }
  # 3) Stouffer（signed）& Fisher
  Z <- sign(L) * qnorm(P / 2, lower.tail = FALSE); W <- sqrt(N)
  stouffer_z <- rowSums(W * Z, na.rm = TRUE) / sqrt(rowSums(W^2 * !is.na(Z), na.rm = TRUE))
  fisher_chi <- -2 * rowSums(log(P), na.rm = TRUE)
  comb <- data.table(gene = rownames(P), stouffer_z = stouffer_z, stouffer_P = 2 * pnorm(-abs(stouffer_z)),
                     fisher_P = pchisq(fisher_chi, 2 * rowSums(!is.na(P)), lower.tail = FALSE))
  # 4) RRA
  rra <- data.table(gene = rownames(L))
  if (has_rra) {
    up_lists <- lapply(ds, function(x) d[dataset == x][order(-stat), gene])
    dn_lists <- lapply(ds, function(x) d[dataset == x][order(stat), gene])
    nuniv <- length(unique(d$gene))
    ru <- RobustRankAggreg::aggregateRanks(up_lists, N = nuniv); rd <- RobustRankAggreg::aggregateRanks(dn_lists, N = nuniv)
    rra <- merge(rra, data.table(gene = ru$Name, RRA_up_score = ru$Score), by = "gene", all.x = TRUE)
    rra <- merge(rra, data.table(gene = rd$Name, RRA_down_score = rd$Score), by = "gene", all.x = TRUE)
    # aggregateRanks 的 Score 已為經 list 數校正的 rho P 值；再做 BH
    rra[, `:=`(RRA_up_FDR = p.adjust(RRA_up_score, "BH"), RRA_down_FDR = p.adjust(RRA_down_score, "BH"))]
  }
  meta <- Reduce(function(a, b) merge(a, b, by = "gene", all = TRUE), list(dirc, re, re_lfc, comb, rra))
  meta[, `:=`(meta_FDR = p.adjust(meta_P, "BH"), stouffer_FDR = p.adjust(stouffer_P, "BH"), fisher_FDR = p.adjust(fisher_P, "BH"))]
  meta[, gene_display := display_symbol(gene)]
  meta[, reproducible_2plus := pmax(n_up_nomP, n_down_nomP) >= 2 & (n_up_nomP == 0 | n_down_nomP == 0)]
  meta[, common_all := n_datasets == length(ds) & (n_up_DEG == length(ds) | n_down_DEG == length(ds))]
  meta[, meta_call := fcase(meta_FDR < 0.05 & meta_g > 0 & I2 < 0.75, "HPV_up_consistent",
                            meta_FDR < 0.05 & meta_g < 0 & I2 < 0.75, "HPV_down_consistent",
                            meta_FDR < 0.05 & I2 >= 0.75, "significant_but_heterogeneous", default = "NS")]
  setorder(meta, meta_P)
  safe_fwrite(meta, pp("meta", paste0("meta_", tag, ".csv")))
  safe_fwrite(meta[reproducible_2plus == TRUE & n_up_nomP >= 2], pp("meta", paste0("HPVup_reproduced2plus_", tag, ".csv")))
  safe_fwrite(meta[reproducible_2plus == TRUE & n_down_nomP >= 2], pp("meta", paste0("HPVdown_reproduced2plus_", tag, ".csv")))
  safe_fwrite(meta[common_all == TRUE], pp("meta", paste0("common_all_datasets_", tag, ".csv")))

  # 5) UpSet（每個資料集的 DEG up/down）
  if (has_upset) {
    sets <- c(setNames(lapply(ds, function(x) d[dataset == x & is_DEG & logFC > 0, gene]), paste0(ds, "_up")),
              setNames(lapply(ds, function(x) d[dataset == x & is_DEG & logFC < 0, gene]), paste0(ds, "_down")))
    sets <- sets[lengths(sets) > 0]
    if (length(sets) >= 2) save_fig(function() print(UpSetR::upset(UpSetR::fromList(sets), nsets = length(sets),
                                                                    order.by = "freq", nintersects = 30)),
                                    paste0("Fig9_UpSet_", tag), 9, 5.5, subdir = "meta")
  }
  # 6) rank-rank
  tmat <- wide("stat")
  sc <- cor(tmat, method = "spearman", use = "pairwise.complete.obs")
  safe_fwrite(as.data.table(sc, keep.rownames = "dataset"), pp("meta", paste0("rank_spearman_", tag, ".csv")))
  pr <- combn(ds, 2, simplify = FALSE)
  for (p2 in head(pr, 6)) {
    t1 <- setNames(tmat[, p2[1]], rownames(tmat)); t2 <- setNames(tmat[, p2[2]], rownames(tmat))
    ok <- !is.na(t1) & !is.na(t2)
    if (sum(ok) > 1000) save_fig(rrho_plot(t1[ok], t2[ok], p2[1], p2[2]) + ggtitle(paste(tag, "rank-rank")),
                                 paste0("FigS_RRHO_", tag, "_", p2[1], "_vs_", p2[2]), 5.5, 4.6, subdir = "meta")
  }
  # 7) 核心基因 forest plot（metafor REML + Knapp–Hartung）
  fr <- d[gene %in% CORE]
  if (nrow(fr) && has_metafor) {
    fp <- rbindlist(lapply(split(fr, fr$gene), function(x) {
      if (nrow(x) < 2) return(x[, .(gene, dataset, est = hedges_g, lo = hedges_g - 1.96 * sqrt(var_g),
                                    hi = hedges_g + 1.96 * sqrt(var_g), n = n_case + n_ref, type = "study")])
      m <- metafor::rma(yi = x$hedges_g, vi = x$var_g, method = "REML", test = "knha")
      rbind(x[, .(gene, dataset, est = hedges_g, lo = hedges_g - 1.96 * sqrt(var_g), hi = hedges_g + 1.96 * sqrt(var_g),
                  n = n_case + n_ref, type = "study")],
            data.table(gene = x$gene[1], dataset = sprintf("RE model (I²=%.0f%%, P=%.2g)", m$I2, m$pval),
                       est = as.numeric(m$b), lo = m$ci.lb, hi = m$ci.ub, n = sum(x$n_case + x$n_ref), type = "pooled"))
    }))
    fp[, gene := display_symbol(gene)]
    safe_fwrite(fp, pp("tables", paste0("Table_4_core_gene_meta_", tag, ".csv")))
    p <- ggplot(fp, aes(est, dataset, xmin = lo, xmax = hi, color = type)) +
      geom_vline(xintercept = 0, lty = 2) + geom_errorbarh(height = 0.2) + geom_point(aes(size = n, shape = type)) +
      scale_shape_manual(values = c(study = 15, pooled = 18)) + scale_color_manual(values = c(study = "grey20", pooled = "#C0392B")) +
      facet_wrap(~gene, scales = "free_y", ncol = 1) + labs(x = "Hedges' g (HPV⁺/case vs HPV⁻/ref)", y = NULL, title = tag) +
      theme_pub()
    save_fig(p, paste0("Fig8_core_forest_", tag), 7, 2 + 1.3 * length(unique(fp$gene)), subdir = "meta")
  }
}
finish_script("06_meta_analysis")
