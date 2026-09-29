# ============================================================
# 10_single_cell.R — scRNA-seq：細胞來源定位、HPV 組成差異、patient-level pseudobulk
#
# 主要資料：GSE164690（Kürten et al.；HNSCC CD45⁺/CD45⁻ 與 PBMC；HPV⁺/HPV⁻）
# 其他：GSE139324（Cillo et al.；僅 CD45⁺ 免疫細胞 → 無法回答腫瘤細胞內在表現）、
#       GSE182227（Puram et al.；HPV⁺/HPV⁻ OPSCC）
#
# 輸入：00_metadata/singlecell_sample_sheet.csv（可用 --make-sheet 由 RAW 檔自動產生後人工補齊）
#   欄位：dataset, sample_id, patient_id, gsm, path, format(10x_dir|h5|mtx_prefix), tissue(tumor|PBMC|normal),
#         sort(CD45pos|CD45neg|total), hpv_binary(HPV_pos|HPV_neg), hpv_evidence_level, anatomic_site
#
# 關鍵原則：
#   * 不把 single cell 當獨立樣本：所有 HPV⁺ vs HPV⁻ 推論均在 patient level（比例、pseudobulk、score 平均）
#   * CD45⁺-sorted 資料不能用來判斷腫瘤細胞是否表現某基因；CD45⁻ 與 CD45⁺ 分開計算組成
#   * Malignant cell：epithelial cluster + inferCNV（若可用）確認；未經 CNV 確認者標示 putative_malignant
# 用法：
#   Rscript scripts/10_single_cell.R --make-sheet GSE164690
#   Rscript scripts/10_single_cell.R GSE164690 [--max-cells-per-sample 3000]
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
source(file.path(.src(), "utils.R"))
require_pkgs(c("Seurat", "Matrix")); suppressPackageStartupMessages({ library(Seurat); library(Matrix) })
set_project_seed(); start_log("10_single_cell")
has <- function(p) requireNamespace(p, quietly = TRUE)
CORE <- harmonize_symbols(CFG$core_genes)
args <- commandArgs(trailingOnly = TRUE)
QC <- list(min_features = 200, max_features = 7000, min_counts = 500, max_mt = 20, min_cells_pseudobulk = 20)
max_cells <- if ("--max-cells-per-sample" %in% args) as.integer(args[which(args == "--max-cells-per-sample") + 1]) else Inf

# ---------- 1. 由 RAW 檔建立 sample sheet ----------
sheet_f <- pp("metadata", "singlecell_sample_sheet.csv")
if ("--make-sheet" %in% args) {
  gse <- setdiff(args, "--make-sheet")[1]
  raw <- pdir("raw", gse, "RAW")
  tars <- list.files(pdir("raw", gse), "_RAW\\.tar$", full.names = TRUE); if (length(tars)) utils::untar(tars[1], exdir = raw)
  fs <- list.files(raw, full.names = TRUE)
  gsm <- sub("^(GSM\\d+).*", "\\1", basename(fs))
  pre <- unique(sub("(barcodes|features|genes|matrix)\\.(tsv|mtx)(\\.gz)?$", "", fs[grepl("matrix\\.mtx", fs)]))
  h5 <- fs[grepl("\\.h5$", fs)]
  sheet <- rbind(data.table(path = pre, format = "mtx_prefix"), data.table(path = h5, format = "h5"))
  sheet[, gsm := sub("^(GSM\\d+).*", "\\1", basename(path))]
  sm <- tryCatch(read_sample_map(gse), error = function(e) NULL)
  sheet[, `:=`(dataset = gse, sample_id = sub("_$", "", basename(path)), patient_id = NA_character_, tissue = NA_character_,
               sort = NA_character_, hpv_binary = NA_character_, hpv_evidence_level = NA_character_, anatomic_site = NA_character_)]
  if (!is.null(sm)) {
    sheet[sm, on = "gsm", `:=`(hpv_binary = i.hpv_binary, hpv_evidence_level = i.hpv_evidence_level, anatomic_site = i.anatomic_site)]
    sheet[sm, on = "gsm", title := i.title]
  }
  old <- if (file.exists(sheet_f)) fread(sheet_f)[dataset != gse] else NULL
  fwrite(rbind(old, sheet, fill = TRUE), sheet_f)
  log_msg("已產生 ", sheet_f, "：請人工補齊 patient_id / tissue / sort / HPV（依原始論文 supplementary），再重新執行")
  quit(save = "no")
}

gse <- args[grepl("^GSE", args)][1]; if (is.na(gse)) gse <- "GSE164690"
assert_that(file.exists(sheet_f), "缺少 singlecell_sample_sheet.csv；先執行 --make-sheet")
sheet <- fread(sheet_f)[dataset == gse]
assert_that(nrow(sheet) > 0, paste("sample sheet 中沒有", gse))
miss <- sheet[is.na(patient_id) | is.na(hpv_binary) | is.na(tissue)]
if (nrow(miss)) log_msg("[警告] ", nrow(miss), " 個樣本缺 patient_id/HPV/tissue → 排除：", paste(miss$sample_id, collapse = ","))
sheet <- sheet[!is.na(patient_id) & !is.na(hpv_binary) & !is.na(tissue)]
out_dir <- pdir("singlecell", gse)

# ---------- 2. 讀取、QC、doublet ----------
read_one <- function(r) {
  m <- switch(r$format,
    "10x_dir" = Read10X(r$path),
    "h5" = Read10X_h5(r$path),
    "mtx_prefix" = {
      ff <- list.files(dirname(r$path), paste0("^", basename(r$path)), full.names = TRUE)
      ReadMtx(mtx = ff[grepl("matrix", ff)], cells = ff[grepl("barcodes", ff)], features = ff[grepl("features|genes", ff)])
    })
  if (is.list(m)) m <- m[[1]]
  rownames(m) <- harmonize_symbols(rownames(m)); m <- m[!duplicated(rownames(m)), ]
  so <- CreateSeuratObject(m, project = r$sample_id, min.cells = 3, min.features = 100)
  for (v in c("dataset", "sample_id", "patient_id", "gsm", "tissue", "sort", "hpv_binary", "hpv_evidence_level", "anatomic_site"))
    so[[v]] <- r[[v]]
  so[["percent.mt"]] <- PercentageFeatureSet(so, pattern = "^MT-")
  n0 <- ncol(so)
  keep <- so$nFeature_RNA >= QC$min_features & so$nFeature_RNA <= QC$max_features &
    so$nCount_RNA >= QC$min_counts & so$percent.mt < QC$max_mt
  if (sum(keep) < 50) stop("QC 後細胞數 < 50（原 ", n0, "）；請檢查 QC 閾值或檔案格式")
  so <- so[, keep]
  if (has("scDblFinder") && ncol(so) > 200) {
    sce <- scDblFinder::scDblFinder(as.SingleCellExperiment(so)); so$dbl <- sce$scDblFinder.class
    so <- subset(so, subset = dbl == "singlet")
  }
  if (is.finite(max_cells) && ncol(so) > max_cells) so <- so[, sample(colnames(so), max_cells)]
  log_msg(r$sample_id, "：", n0, " → ", ncol(so), " cells after QC/doublet removal")
  data.table(sample_id = r$sample_id, cells_raw = n0, cells_qc = ncol(so)) -> qc_row
  attr(so, "qc_row") <- qc_row; so
}
objs <- lapply(seq_len(nrow(sheet)), function(i) tryCatch(read_one(sheet[i]), error = function(e) { log_msg("[錯誤] ", sheet$sample_id[i], "：", conditionMessage(e)); NULL }))
objs <- objs[!sapply(objs, is.null)]
safe_fwrite(rbindlist(lapply(objs, attr, "qc_row")), file.path(out_dir, "QC_cells_per_sample.csv"))
assert_that(length(objs) > 0, "沒有任何樣本成功讀取")
so <- if (length(objs) == 1) RenameCells(objs[[1]], add.cell.id = objs[[1]]$sample_id[1]) else
  JoinLayers(merge(objs[[1]], objs[-1], add.cell.ids = sapply(objs, function(o) o$sample_id[1])))

# ---------- 3. Normalization、patient-aware integration、clustering ----------
so <- NormalizeData(so) |> FindVariableFeatures(nfeatures = 3000) |> ScaleData() |> RunPCA(npcs = 40, verbose = FALSE)
red <- "pca"
if (has("harmony")) { so <- harmony::RunHarmony(so, group.by.vars = "patient_id", verbose = FALSE); red <- "harmony" } else
  log_msg("[注意] 未安裝 harmony：未做 patient-aware integration（UMAP 可能受病人效應主導）")
so <- RunUMAP(so, reduction = red, dims = 1:30, verbose = FALSE) |> FindNeighbors(reduction = red, dims = 1:30) |> FindClusters(resolution = 0.6)

# ---------- 4. Cell-type annotation ----------
markers <- list(
  Malignant_epithelial = c("KRT5", "KRT14", "KRT17", "KRT6A", "SFN", "EPCAM"),
  T_CD8 = c("CD8A", "CD8B", "CD3D"), T_CD4 = c("CD4", "IL7R", "CD3D"), Treg = c("FOXP3", "IL2RA", "CTLA4"),
  NK = c("NCR1", "KLRF1", "KLRD1", "GNLY"), B = c("MS4A1", "CD79A", "CD19"), Plasma = c("MZB1", "JCHAIN", "IGKC"),
  Macrophage = c("CD68", "CD163", "C1QA", "C1QB", "APOE"), Monocyte = c("CD14", "FCN1", "S100A8"),
  DC = c("CLEC9A", "CD1C", "LAMP3", "FCER1A"), Mast = c("TPSAB1", "CPA3"), CAF = c("COL1A1", "COL1A2", "DCN", "FAP", "PDGFRB"),
  Endothelial = c("PECAM1", "VWF", "CDH5"), Myocyte = c("ACTA2", "DES", "MYH11"))
markers <- lapply(markers, intersect, rownames(so)); markers <- markers[lengths(markers) >= 2]
so <- AddModuleScore(so, markers, name = "mk_", ctrl = min(100, floor(nrow(so) / 30)))
mk <- as.matrix(so@meta.data[, grep("^mk_", colnames(so@meta.data))]); colnames(mk) <- names(markers)
cl_score <- aggregate(mk, list(cluster = so$seurat_clusters), mean)
cl_type <- setNames(names(markers)[apply(cl_score[, -1], 1, which.max)], cl_score$cluster)
so$cell_type_marker <- unname(cl_type[as.character(so$seurat_clusters)])
if (has("SingleR") && has("celldex")) {
  ref <- tryCatch(celldex::HumanPrimaryCellAtlasData(), error = function(e) NULL)   # 需 ExperimentHub 網路
  if (!is.null(ref)) {
    pr <- SingleR::SingleR(GetAssayData(so, layer = "data"), ref, labels = ref$label.main, clusters = so$seurat_clusters)
    so$cell_type_SingleR <- pr$labels[match(so$seurat_clusters, rownames(pr))]
  }
}
so$cell_type <- so$cell_type_marker
safe_fwrite(as.data.table(cl_score)[, assigned := cl_type[as.character(cluster)]], file.path(out_dir, "cluster_marker_scores.csv"))

# ---------- 5. Malignant 確認（inferCNV）----------
so$malignant_status <- ifelse(so$cell_type == "Malignant_epithelial", "putative_malignant", "non_malignant")
if (has("infercnv") && file.exists(pp("metadata", "hg38_gene_order.txt"))) {
  epi <- colnames(so)[so$cell_type == "Malignant_epithelial"]; refc <- colnames(so)[so$cell_type %in% c("T_CD4", "T_CD8", "Macrophage")]
  refc <- sample(refc, min(2000, length(refc))); cells <- c(epi, refc)
  ann <- data.frame(row.names = cells, grp = ifelse(cells %in% epi, paste0("epi_", so$patient_id[cells]), "reference"))
  ic <- infercnv::CreateInfercnvObject(GetAssayData(so, layer = "counts")[, cells], annotations_file = ann,
                                       gene_order_file = pp("metadata", "hg38_gene_order.txt"), ref_group_names = "reference")
  ic <- infercnv::run(ic, cutoff = 0.1, out_dir = file.path(out_dir, "infercnv"), cluster_by_groups = TRUE, denoise = TRUE, HMM = FALSE, num_threads = 4)
  cnv <- ic@expr.data; score <- colMeans((cnv - 1)^2)
  thr <- quantile(score[colnames(cnv) %in% refc], 0.95)
  so$cnv_score <- NA; so$cnv_score[names(score)] <- score
  so$malignant_status[epi[score[epi] > thr]] <- "CNV_confirmed_malignant"
} else log_msg("[注意] 未執行 inferCNV（未安裝或缺 00_metadata/hg38_gene_order.txt）→ 上皮細胞標為 putative_malignant")

p1 <- DimPlot(so, group.by = "cell_type", label = TRUE, repel = TRUE, raster = TRUE) + ggtitle(paste(gse, "cell types"))
p2 <- DimPlot(so, group.by = "hpv_binary", raster = TRUE, cols = HPV_COLORS) + ggtitle("HPV status (patient-level)")
p3 <- DimPlot(so, group.by = "patient_id", raster = TRUE) + NoLegend() + ggtitle("patient")
save_fig(p1 + p2 + p3, "Fig15_scUMAP", 17, 5.5, subdir = "singlecell")

# ---------- 6. 核心基因定位（Q5）----------
cg <- intersect(CORE, rownames(so))
save_fig(DotPlot(so, features = cg, group.by = "cell_type") + RotatedAxis() + ggtitle("Core genes by cell type"),
         "Fig16a_scDotPlot_core", 8, 6, subdir = "singlecell")
save_fig(VlnPlot(so, features = cg, group.by = "cell_type", split.by = "hpv_binary", pt.size = 0, ncol = 1, cols = HPV_COLORS[c("HPV_neg", "HPV_pos")]),
         "Fig16b_scViolin_core", 11, 3 * length(cg), subdir = "singlecell")
cnt <- GetAssayData(so, layer = "counts")
md <- as.data.table(so@meta.data, keep.rownames = "cell")
share <- rbindlist(lapply(cg, function(g) {
  md[, umi := cnt[g, cell]]
  md[, .(n_cells = .N, frac_expr = mean(umi > 0), mean_umi = mean(umi), total_umi = sum(umi)),
     by = .(patient_id, hpv_binary, tissue, sort, cell_type)][, `:=`(gene = display_symbol(g),
     share_of_gene_umi = total_umi / sum(total_umi)), by = .(patient_id, tissue, sort)]
}))
safe_fwrite(share, file.path(out_dir, "core_gene_celltype_share_per_patient.csv"))
# 摘要：每個基因在 tumor 組織中，UMI 主要來自哪一種細胞（跨病人中位數）
safe_fwrite(share[tissue == "tumor", .(median_share = median(share_of_gene_umi), median_frac_expr = median(frac_expr), n_patients = uniqueN(patient_id)),
                  by = .(gene, sort, cell_type)][order(gene, sort, -median_share)],
            pp("tables", paste0("Table_9_", gse, "_core_gene_cell_origin.csv")))

# ---------- 7. 組成差異（patient level）----------
comp <- md[tissue == "tumor", .N, by = .(patient_id, hpv_binary, sort, cell_type)][, prop := N / sum(N), by = .(patient_id, sort)]
comp_test <- comp[, { a <- prop[hpv_binary == "HPV_pos"]; b <- prop[hpv_binary == "HPV_neg"]
  .(median_pos = median(a), median_neg = median(b), n_pos = length(a), n_neg = length(b),
    P = if (length(a) >= 3 && length(b) >= 3) suppressWarnings(wilcox.test(a, b)$p.value) else NA_real_) }, by = .(sort, cell_type)]
comp_test[, FDR := p.adjust(P, "BH"), by = sort]
safe_fwrite(comp_test, pp("tables", paste0("Table_10_", gse, "_composition_HPV.csv")))
save_fig(ggplot(comp, aes(hpv_binary, prop, fill = hpv_binary)) + geom_boxplot(outlier.shape = NA, alpha = 0.6) + geom_jitter(width = 0.1, size = 0.8) +
           facet_wrap(sort ~ cell_type, scales = "free_y") + scale_fill_manual(values = HPV_COLORS) +
           labs(title = "Cell-type proportion per patient (tumor)", y = "proportion", x = NULL) + theme_pub(8) + theme(legend.position = "none"),
         "Fig15b_sc_composition", 12, 9, subdir = "singlecell")

# ---------- 8. Pseudobulk DE（patient × cell type）----------
if (has("DESeq2")) {
  pb_res <- list()
  for (ct in c("Malignant_epithelial", "T_CD8", "NK", "Macrophage", "CAF", "Treg")) {
    cells <- md[tissue == "tumor" & cell_type == ct]
    grp <- cells[, .N, by = .(patient_id, hpv_binary)][N >= QC$min_cells_pseudobulk]
    if (sum(grp$hpv_binary == "HPV_pos") < 3 || sum(grp$hpv_binary == "HPV_neg") < 3) { log_msg("pseudobulk 略過 ", ct, "（每組病人 < 3）"); next }
    pbm <- sapply(grp$patient_id, function(p) Matrix::rowSums(cnt[, cells[patient_id == p, cell], drop = FALSE]))
    dds <- DESeq2::DESeqDataSetFromMatrix(pbm[rowSums(pbm >= 10) >= 3, ], data.frame(hpv = factor(grp$hpv_binary, c("HPV_neg", "HPV_pos"))), ~ hpv)
    dds <- DESeq2::DESeq(dds, quiet = TRUE); r <- as.data.table(as.data.frame(DESeq2::results(dds, name = "hpv_HPV_pos_vs_HPV_neg")), keep.rownames = "gene")
    r[, `:=`(cell_type = ct, n_pos = sum(grp$hpv_binary == "HPV_pos"), n_neg = sum(grp$hpv_binary == "HPV_neg"))]
    pb_res[[ct]] <- r
  }
  pb <- rbindlist(pb_res)
  if (nrow(pb)) { safe_fwrite(pb, file.path(out_dir, "pseudobulk_DESeq2_HPVpos_vs_neg.csv"))
    safe_fwrite(pb[gene %in% CORE], pp("tables", paste0("Table_11_", gse, "_pseudobulk_core_genes.csv"))) }
}

# ---------- 9. Pathway score（patient-level 比較）與 proliferating malignant ----------
sig <- fread(pp("metadata", "gene_signatures.csv"))[!grepl("^Cell_", signature)]
gs <- lapply(split(harmonize_symbols(sig$gene), sig$signature), intersect, rownames(so)); gs <- gs[lengths(gs) >= 2]
so <- AddModuleScore(so, gs, name = "sig_", ctrl = min(100, floor(nrow(so) / 30)))
sc_cols <- grep("^sig_", colnames(so@meta.data), value = TRUE); names(sc_cols) <- names(gs)
so <- CellCycleScoring(so, s.features = intersect(cc.genes.updated.2019$s.genes, rownames(so)),
                       g2m.features = intersect(cc.genes.updated.2019$g2m.genes, rownames(so)),
                       ctrl = min(100, floor(nrow(so) / 30)))
md <- as.data.table(so@meta.data, keep.rownames = "cell")
md[, proliferating := Phase %in% c("S", "G2M")]
pat <- md[tissue == "tumor", lapply(.SD, mean), by = .(patient_id, hpv_binary, cell_type), .SDcols = sc_cols]
setnames(pat, sc_cols, names(sc_cols))
pl <- melt(pat, id.vars = c("patient_id", "hpv_binary", "cell_type"), variable.name = "signature", value.name = "score")
pt <- pl[, { a <- score[hpv_binary == "HPV_pos"]; b <- score[hpv_binary == "HPV_neg"]
  .(delta = mean(a) - mean(b), n_pos = length(a), n_neg = length(b),
    P = if (length(a) >= 3 && length(b) >= 3) wilcox.test(a, b)$p.value else NA_real_) }, by = .(cell_type, signature)]
pt[, FDR := p.adjust(P, "BH")]
safe_fwrite(pt, pp("tables", paste0("Table_12_", gse, "_sc_pathway_scores_patient_level.csv")))
# MTHFD2/OGT 是否集中於 proliferating malignant cells（每位病人內比較，再跨病人 paired Wilcoxon）
mal <- md[cell_type == "Malignant_epithelial" & tissue == "tumor"]
if (nrow(mal)) {
  ex <- GetAssayData(so, layer = "data")
  pr <- rbindlist(lapply(intersect(c("MTHFD2", "OGT", "OGA", "CD274"), rownames(so)), function(g) {
    mal[, e := ex[g, cell]]
    x <- mal[, .(prolif = mean(e[proliferating]), nonprolif = mean(e[!proliferating]), n_prolif = sum(proliferating)), by = .(patient_id, hpv_binary)][n_prolif >= 10]
    data.table(gene = display_symbol(g), n_patients = nrow(x), median_diff = median(x$prolif - x$nonprolif),
               paired_P = if (nrow(x) >= 3) wilcox.test(x$prolif, x$nonprolif, paired = TRUE)$p.value else NA_real_)
  }))
  safe_fwrite(pr, pp("tables", paste0("Table_13_", gse, "_proliferating_malignant_core.csv")))
}

# ---------- 10. Ligand–receptor ----------
if (has("CellChat")) {
  for (h in c("HPV_pos", "HPV_neg")) {
    sub <- subset(so, subset = hpv_binary == h & tissue == "tumor")
    cc <- CellChat::createCellChat(GetAssayData(sub, layer = "data"), meta = sub@meta.data, group.by = "cell_type")
    cc@DB <- CellChat::CellChatDB.human
    cc <- CellChat::subsetData(cc) |> CellChat::identifyOverExpressedGenes() |> CellChat::identifyOverExpressedInteractions()
    cc <- CellChat::computeCommunProb(cc, type = "triMean") |> CellChat::filterCommunication(min.cells = 10) |> CellChat::computeCommunProbPathway() |> CellChat::aggregateNet()
    saveRDS(cc, file.path(out_dir, paste0("cellchat_", h, ".rds")))
    safe_fwrite(as.data.table(CellChat::subsetCommunication(cc)), file.path(out_dir, paste0("cellchat_LR_", h, ".csv")))
    save_fig(function() CellChat::netVisual_circle(cc@net$weight, weight.scale = TRUE, title.name = paste("Interaction strength", h)),
             paste0("Fig17_CellChat_", h), 7, 7, subdir = "singlecell")
    pdl1 <- tryCatch(CellChat::subsetCommunication(cc, signaling = c("PD-L1", "PDL2", "MHC-I")), error = function(e) NULL)
    if (!is.null(pdl1)) safe_fwrite(as.data.table(pdl1), file.path(out_dir, paste0("cellchat_PDL1_MHCI_", h, ".csv")))
  }
} else log_msg("[注意] 未安裝 CellChat；替代：LIANA（saezlab/liana）")
if (has("nichenetr")) log_msg("NicheNet：需下載 ligand_target_matrix（Zenodo）；請依 README 步驟以 malignant 為 receiver、CD274 為 target gene 執行")

saveRDS(so, file.path(out_dir, paste0(gse, "_seurat_annotated.rds")))
finish_script("10_single_cell")
