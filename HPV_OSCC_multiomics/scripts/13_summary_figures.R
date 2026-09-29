# ============================================================
# 13_summary_figures.R — Fig 1 dataset selection flowchart、Fig 2 audit table、Fig 3 sample annotation heatmap、
#                         Fig 20 proposed mechanism（假說圖；虛線 = 未經 perturbation/rescue 驗證）
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
source(file.path(.src(), "utils.R"))
set_project_seed(); start_log("13_summary_figures")

# ---------- Fig 1 flowchart（數字取自 audit table 與 02 自動計數）----------
audit <- fread(pp("metadata", "dataset_audit_table.csv"))
cnt_f <- pp("tables", "Table_S2_sample_counts_by_dataset.csv")
cnt <- if (file.exists(cnt_f)) fread(cnt_f) else NULL
n_screen <- nrow(audit)
n_incl <- audit[grepl("^Include", inclusion_decision), .N]
n_cond <- audit[grepl("^Conditional", inclusion_decision), .N]
n_excl <- n_screen - n_incl - n_cond
lab_pri <- if (!is.null(cnt)) sprintf("Primary (oral cavity OSCC)\nHPV⁺ %d / HPV⁻ %d", sum(cnt$n_primary_OSCC_HPVpos), sum(cnt$n_primary_OSCC_HPVneg)) else "Primary (oral cavity OSCC)\n(n 待 02 稽核)"
lab_sec <- if (!is.null(cnt)) sprintf("Secondary (OPSCC)\nHPV⁺ %d / HPV⁻ %d", sum(cnt$n_OPSCC_HPVpos), sum(cnt$n_OPSCC_HPVneg)) else "Secondary (OPSCC)\n(n 待 02 稽核)"
boxes <- data.table(
  id = 1:8, x = c(5, 5, 5, 9, 2, 5, 8, 5), y = c(10, 8.2, 6.4, 6.4, 4.2, 4.2, 4.2, 2.2),
  label = c(sprintf("GEO / literature screening\n%d candidate datasets", n_screen),
            "GSM-level audit\n(HPV evidence level A–E; anatomic site; sample type)",
            sprintf("Included: %d  |  Conditional: %d", n_incl, n_cond),
            sprintf("Supplementary / audit-only / pending: %d\n(single HPV group, possible duplicate series,\nno reliable HPV annotation)", n_excl),
            lab_pri, lab_sec, "Sensitivity (mixed HNSCC)\nsite as covariate",
            "Per-dataset DEG → meta-analysis\n→ pathway / immune / single-cell / survival"))
edges <- data.table(from = c(1, 2, 2, 3, 3, 3, 5, 6, 7), to = c(2, 3, 4, 5, 6, 7, 8, 8, 8))
seg <- merge(merge(edges, boxes[, .(from = id, x0 = x, y0 = y)], by = "from"), boxes[, .(to = id, x1 = x, y1 = y)], by = "to")
p1 <- ggplot() + geom_segment(data = seg, aes(x0, y0 - 0.55, xend = x1, yend = y1 + 0.55), arrow = arrow(length = unit(2, "mm"))) +
  geom_label(data = boxes, aes(x, y, label = label), size = 2.8, label.padding = unit(3, "mm"), fill = c("grey95", "grey95", "#EAF2F8", "#FDEDEC", "#FEF9E7", "#FEF9E7", "#FEF9E7", "#E9F7EF")) +
  xlim(0, 11) + ylim(1.2, 11) + theme_void() + ggtitle("Fig. 1 Dataset selection flow")
save_fig(p1, "Fig1_dataset_selection_flowchart", 9, 8)

# ---------- Fig 2 audit table（精簡版圖表）----------
keep <- c("accession", "data_type", "platform", "hpv_detection_method", "hpv_evidence_level_expected", "inclusion_decision")
a2 <- audit[, ..keep]
a2[, inclusion_decision := substr(inclusion_decision, 1, 40)]
a2[, hpv_detection_method := substr(hpv_detection_method, 1, 38)]
a2[, platform := substr(platform, 1, 30)]
tl <- melt(a2[, row := .I], id.vars = "row", variable.name = "col", value.name = "txt")
p2 <- ggplot(tl, aes(col, -row, label = txt)) + geom_tile(fill = ifelse(tl$row %% 2 == 0, "grey96", "white"), color = "grey85") +
  geom_text(size = 2.1) + scale_x_discrete(position = "top") + theme_void() + theme(axis.text.x = element_text(size = 7, face = "bold")) +
  ggtitle("Fig. 2 Dataset audit (full table: 00_metadata/dataset_audit_table.csv)")
save_fig(p2, "Fig2_dataset_audit_table", 14, 0.8 + 0.28 * nrow(a2))

# ---------- Fig 3 sample-level HPV / site annotation heatmap ----------
maps <- list.files(pdir("metadata", "gsm_mapping"), "_samples_auto\\.csv$", full.names = TRUE)
maps <- maps[!grepl("^ALL_", basename(maps))]
if (length(maps) && requireNamespace("ComplexHeatmap", quietly = TRUE)) {
  sm <- rbindlist(lapply(maps, fread), fill = TRUE)[sample_type == "tumor"]
  setorder(sm, dataset, hpv_group_detail, anatomic_site)
  mat <- matrix("0", 1, nrow(sm))
  col_fun <- function(v, pal) setNames(pal[seq_along(unique(v))], unique(v))
  ha <- ComplexHeatmap::HeatmapAnnotation(
    dataset = sm$dataset, HPV_group = sm$hpv_group_detail, HPV_evidence = sm$hpv_evidence_level, site = sm$anatomic_site,
    col = list(HPV_evidence = c(A = "#1B5E20", B = "#66BB6A", C = "#FBC02D", D = "#EF6C00", E = "#9E9E9E")),
    annotation_name_gp = grid::gpar(fontsize = 8))
  hm <- ComplexHeatmap::Heatmap(mat, top_annotation = ha, show_heatmap_legend = FALSE, col = c("0" = "white"),
                                cluster_columns = FALSE, height = unit(1, "mm"), column_split = sm$dataset,
                                column_title_gp = grid::gpar(fontsize = 7), column_title_rot = 45)
  save_fig(hm, "Fig3_sample_annotation_heatmap", 13, 3.5)
}

# ---------- Fig 20 proposed mechanism（假說）----------
nodes <- data.table(
  id = c("HPV", "MTHFD2", "OGT", "OGlc", "PDL1", "ESC", "IMM", "CORO1A", "EV", "EVPDL1", "TIME"),
  x = c(1, 3, 5, 7, 9, 11, 1, 3, 5, 7, 9), y = c(4, 4, 4, 4, 4, 4, 1.5, 1.5, 1.5, 1.5, 1.5),
  label = c("HPV E6/E7\ntranscriptional activity", "MTHFD2 /\nmito one-carbon", "OGT–OGA\nbalance", "O-GlcNAc\n(protein level)",
            "CD274 / PD-L1", "NK / T-cell\nkilling ↓", "HPV-related\nimmune pressure", "CORO1A\n(cell of origin?)", "Cytoskeleton /\nvesicle trafficking",
            "Exosomal\nPD-L1", "TIME remodeling /\nimmune escape"))
ed <- data.table(from = c("HPV", "MTHFD2", "OGT", "OGlc", "PDL1", "IMM", "CORO1A", "EV", "EVPDL1", "HPV"),
                 to = c("MTHFD2", "OGT", "OGlc", "PDL1", "ESC", "CORO1A", "EV", "EVPDL1", "TIME", "IMM"))
ed <- merge(merge(ed, nodes[, .(from = id, x0 = x, y0 = y)], by = "from"), nodes[, .(to = id, x1 = x, y1 = y)], by = "to")
ed[, `:=`(xs = ifelse(x1 > x0, x0 + 0.85, x0), xe = ifelse(x1 > x0, x1 - 0.85, x1), ys = ifelse(y1 < y0, y0 - 0.55, y0), ye = ifelse(y1 < y0, y1 + 0.55, y1))]
p20 <- ggplot() +
  geom_segment(data = ed, aes(xs, ys, xend = xe, yend = ye), linetype = "dashed", arrow = arrow(length = unit(2.2, "mm")), color = "grey30") +
  geom_label(data = nodes, aes(x, y, label = label), size = 2.8, fill = c("#FADBD8", "#FCF3CF", "#FCF3CF", "#FCF3CF", "#D6EAF8", "#E8DAEF",
                                                                          "#FADBD8", "#D5F5E3", "#D5F5E3", "#D6EAF8", "#E8DAEF")) +
  annotate("text", x = 6, y = 5.3, label = "Axis 1 (hypothesis): HPV → MTHFD2 → OGT/OGA → O-GlcNAc → PD-L1 → immune escape", size = 3, fontface = "bold") +
  annotate("text", x = 5, y = 2.8, label = "Axis 2 (hypothesis): immune pressure → CORO1A → EV trafficking → exosomal PD-L1", size = 3, fontface = "bold") +
  annotate("text", x = 6, y = 0.2, size = 2.6, label = "Dashed arrows = hypothesized links (association only). Solid arrows to be drawn only after perturbation + rescue evidence.") +
  xlim(0, 12.2) + ylim(0, 5.8) + theme_void() + ggtitle("Fig. 20 Proposed working model (not established causality)")
save_fig(p20, "Fig20_proposed_mechanism", 12, 5.5)
finish_script("13_summary_figures")
