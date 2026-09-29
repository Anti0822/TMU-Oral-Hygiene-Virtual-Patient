# ============================================================
# 12_candidate_priority.R — Candidate Priority Score（CPS）
#
# 每個分項標準化到 0–1，再加權（權重可調；預設見 W）。缺資料的分項給 NA，
# 以「可得分項的權重重新正規化」計算，並輸出 completeness 讓讀者知道分數依據多少證據。
#  1 reproducibility      ：同向且 nominal P<0.05 的資料集比例（06 direction consistency）
#  2 effect_size          ：|meta Hedges' g|，以 1.5 截頂
#  3 fdr                  ：-log10(meta FDR)，以 10 截頂
#  4 oral_specificity     ：primary（oral cavity）層是否同向顯著；無 primary 層 → NA
#  5 hpv_evidence         ：支持資料集的最佳 HPV evidence level（A=1, B=.8, C=.5, D=.3, E=.1）
#  6 malignant_specificity：single-cell 中 malignant cells 佔該基因 UMI 的中位比例（Table_9）
#  7 immune_association   ：與 cytotoxic/exhaustion 分數的 purity-adjusted |partial ρ| 最大值（Table_8）
#  8 survival             ：multivariable Cox 最小 FDR 轉換（-log10，截頂 3）/3
#  9 pathway_centrality   ：STRING degree 百分位
# 10 druggability / 11 wet-lab feasibility：00_metadata/druggability_feasibility.csv（人工註記、附依據）
# 另懲罰：I² ≥ 75% 時分數 × 0.8（heterogeneity）
# 注意：CPS 是排序工具，不是統計檢定；最終選擇需人工檢視各分項。
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
source(file.path(.src(), "utils.R"))
set_project_seed(); start_log("12_candidate_priority")
CORE <- harmonize_symbols(CFG$core_genes)
W <- c(reproducibility = 0.15, effect_size = 0.10, fdr = 0.10, oral_specificity = 0.10, hpv_evidence = 0.08,
       malignant_specificity = 0.12, immune_association = 0.08, survival = 0.07, pathway_centrality = 0.05,
       druggability = 0.08, feasibility = 0.07)
assert_that(abs(sum(W) - 1) < 1e-8, "權重總和需為 1")

pick_meta <- function(layer) { f <- pp("meta", paste0("meta_", layer, "__pos_vs_neg.csv")); if (file.exists(f)) fread(f) else NULL }
m_pri <- pick_meta("primary"); m_sec <- pick_meta("secondary"); m_sen <- pick_meta("sensitivity")
base <- if (!is.null(m_pri)) m_pri else if (!is.null(m_sec)) m_sec else m_sen
base_layer <- if (!is.null(m_pri)) "primary" else if (!is.null(m_sec)) "secondary" else "sensitivity"
assert_that(!is.null(base), "找不到任何 pos_vs_neg meta-analysis 結果（需 ≥2 個資料集）")
log_msg("CPS 基礎層：", base_layer, if (base_layer != "primary") "（oral cavity 資料不足，oral_specificity 依 primary 單一資料集結果或 NA）")

cand <- unique(c(CORE, base[meta_call %in% c("HPV_up_consistent", "HPV_down_consistent")][order(meta_P)][1:min(.N, 200), gene]))
S <- base[gene %in% cand, .(gene, meta_g, meta_FDR, I2, n_datasets, n_up_nomP, n_down_nomP)]
S <- merge(data.table(gene = cand), S, by = "gene", all.x = TRUE)
S[, reproducibility := pmax(n_up_nomP, n_down_nomP) / n_datasets * as.numeric(n_up_nomP == 0 | n_down_nomP == 0)]
S[, effect_size := pmin(abs(meta_g), 1.5) / 1.5]
S[, fdr := pmin(-log10(meta_FDR), 10) / 10]

# oral specificity：primary 層 per-dataset 結果（即使只有 1 個資料集）
pri_files <- list.files(pp("bulk", "DEG_tables"), "__primary__pos_vs_neg_full\\.csv$", full.names = TRUE)
if (length(pri_files)) {
  pr <- rbindlist(lapply(pri_files, fread), fill = TRUE)
  pr <- merge(pr, S[, .(gene, meta_g)], by = "gene")
  # oral cavity 層中「與整體 meta 同向且 nominal P<0.05」的資料集比例
  pr <- pr[, .(oral_specificity = mean(P.Value < 0.05 & sign(logFC) == sign(meta_g))), by = gene]
  S <- merge(S, pr, by = "gene", all.x = TRUE)
} else S[, oral_specificity := NA_real_]

# HPV evidence level
lv <- c(A = 1, B = 0.8, C = 0.5, D = 0.3, E = 0.1)
maps <- list.files(pdir("metadata", "gsm_mapping"), "_samples_(auto|curated)\\.csv$", full.names = TRUE)
if (length(maps)) {
  ev <- rbindlist(lapply(maps, fread), fill = TRUE)[!is.na(hpv_binary), .(best = max(lv[hpv_evidence_level], na.rm = TRUE)), by = dataset]
  S[, hpv_evidence := max(ev$best, na.rm = TRUE)]
} else S[, hpv_evidence := NA_real_]

t9 <- list.files(pdir("tables"), "^Table_9_.*core_gene_cell_origin\\.csv$", full.names = TRUE)
if (length(t9)) {
  x <- rbindlist(lapply(t9, fread))[cell_type == "Malignant_epithelial", .(malignant_specificity = max(median_share)), by = gene]
  x[, gene := harmonize_symbols(sub(" \\(.*", "", gene))]
  S <- merge(S, x, by = "gene", all.x = TRUE)
} else S[, malignant_specificity := NA_real_]

t8 <- pp("tables", "Table_8_core_gene_immune_partial_correlation.csv")
if (file.exists(t8)) {
  x <- fread(t8)[hpv == "all" & grepl("CD8|NK|cytotox|Cytotoxic", cell_type, ignore.case = TRUE),
                 .(immune_association = max(abs(rho_partial), na.rm = TRUE)), by = gene]
  x[, gene := harmonize_symbols(sub(" \\(.*", "", gene))]
  S <- merge(S, x, by = "gene", all.x = TRUE)
} else S[, immune_association := NA_real_]

t14 <- pp("tables", "Table_14_survival_all.csv")
if (file.exists(t14)) {
  x <- fread(t14)[!grepl(":", feature), .(survival = min(pmin(-log10(mv_FDR), 3) / 3, na.rm = TRUE)), by = feature]
  x[, gene := harmonize_symbols(sub(" \\(.*", "", feature))][, feature := NULL]
  x[!is.finite(survival), survival := NA]
  S <- merge(S, x, by = "gene", all.x = TRUE)
} else S[, survival := NA_real_]

ppi <- list.files(pdir("pathway"), "^PPI_degree_.*pos_vs_neg\\.csv$", full.names = TRUE)
if (length(ppi)) { x <- rbindlist(lapply(ppi, fread))[, .(degree = max(degree)), by = gene]; x[, pathway_centrality := rank(degree) / .N]
  S <- merge(S, x[, .(gene, pathway_centrality)], by = "gene", all.x = TRUE) } else S[, pathway_centrality := NA_real_]

dg <- fread(pp("metadata", "druggability_feasibility.csv"))[, gene := harmonize_symbols(gene)]
S <- merge(S, dg[, .(gene, druggability, feasibility = wetlab_feasibility, druggability_note, feasibility_note)], by = "gene", all.x = TRUE)

comp <- names(W)
M <- as.matrix(S[, ..comp])
wm <- matrix(W, nrow(M), length(W), byrow = TRUE); wm[is.na(M)] <- 0
S[, completeness := rowSums(wm)]
S[, CPS := rowSums(M * wm, na.rm = TRUE) / pmax(completeness, 1e-9)]
S[!is.na(I2) & I2 >= 0.75, CPS := CPS * 0.8]
S[, gene_display := display_symbol(gene)]
setorder(S, -CPS)
safe_fwrite(S, pp("tables", "Table_17_candidate_priority_score.csv"))

# 分子組合（以成員平均；僅作排序參考）
combos <- list("MTHFD2–OGT/OGA–CD274 axis" = c("MTHFD2", "OGT", "OGA", "CD274"), "CORO1A–EV–CD274 axis" = c("CORO1A", "RAB27A", "CD274"))
cb <- rbindlist(lapply(names(combos), function(n) data.table(combo = n, members = paste(combos[[n]], collapse = "+"),
                                                             mean_CPS = mean(S[gene %in% combos[[n]], CPS]), members_found = sum(S$gene %in% combos[[n]]))))
safe_fwrite(cb, pp("tables", "Table_17b_candidate_combinations.csv"))

top <- head(S[completeness >= 0.5], 25)
long <- melt(top[, c("gene_display", comp), with = FALSE], id.vars = "gene_display")
long[, contrib := value * W[as.character(variable)]]
p <- ggplot(long, aes(reorder(gene_display, contrib, sum, na.rm = TRUE), contrib, fill = variable)) + geom_col() + coord_flip() +
  labs(x = NULL, y = "Weighted contribution to CPS", fill = "Component",
       title = paste0("Candidate Priority Score (base layer: ", base_layer, ")")) + theme_pub()
save_fig(p, "FigS_candidate_priority", 8, 7, subdir = "candidate")
finish_script("12_candidate_priority")
