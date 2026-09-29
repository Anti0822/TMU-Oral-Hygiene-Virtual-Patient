# ============================================================
# 08_enrichment_network.R — GSEA、GO/KEGG/Reactome、TF enrichment、upstream regulator、PPI、WGCNA
#
#  * GSEA：使用 05 的「完整」ranked list（limma t 或 DESeq2 Wald stat），不只用 DEG。
#      fgsea + MSigDB Hallmark / Reactome / GO:BP（msigdbr）；不可用時 fallback：limma::cameraPR
#  * ORA：clusterProfiler（enrichGO BP、enrichKEGG、ReactomePA::enrichPathway），輸入 = 06 的
#      meta-analysis 一致上調／下調基因，universe = 所有資料集皆有測到的基因
#  * TF / upstream regulator：decoupleR + CollecTRI（OmnipathR；需網路）→ ulm 活性；
#      fallback：msigdbr C3 TFT:GTRD 做 fgsea
#  * PPI：STRINGdb（score ≥ 700）於 meta 候選基因 + 核心基因
#  * WGCNA：只在 tumor 樣本數 ≥ 40 的資料集執行（例如 GSE65858、TCGA-HNSC）
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
source(file.path(.src(), "utils.R"))
require_pkgs("limma"); suppressPackageStartupMessages(library(limma))
set_project_seed(); start_log("08_enrichment_network")
has <- function(p) requireNamespace(p, quietly = TRUE)
CORE <- harmonize_symbols(CFG$core_genes)
PRIORITY_TERMS <- c("E2F_TARGETS", "G2M_CHECKPOINT", "DNA_REPAIR", "P53_PATHWAY", "GLYCOLYSIS", "OXIDATIVE_PHOSPHORYLATION",
                    "MTORC1", "MYC_TARGETS", "INTERFERON_ALPHA", "INTERFERON_GAMMA", "EPITHELIAL_MESENCHYMAL",
                    "SERINE", "GLYCINE", "FOLATE", "ONE_CARBON", "ANTIGEN_PROCESSING", "NATURAL_KILLER",
                    "T_CELL_RECEPTOR", "PD_1", "PD_L1", "EXTRACELLULAR_VESICLE", "EXOSOME", "HEXOSAMINE", "O_LINKED_GLYCOSYLATION")

# ---------- gene set collections ----------
collections <- list()
if (has("msigdbr")) {
  get_c <- function(cat, sub = NULL) tryCatch({
    x <- if (is.null(sub)) msigdbr::msigdbr(species = "Homo sapiens", category = cat)
         else msigdbr::msigdbr(species = "Homo sapiens", category = cat, subcategory = sub)
    split(harmonize_symbols(x$gene_symbol), x$gs_name) }, error = function(e) NULL)
  collections$Hallmark <- get_c("H")
  collections$Reactome <- get_c("C2", "CP:REACTOME")
  collections$KEGG     <- get_c("C2", "CP:KEGG")
  collections$GOBP     <- get_c("C5", "GO:BP")
  collections$TFT_GTRD <- get_c("C3", "TFT:GTRD")
}
gmt_dir <- pdir("metadata", "gmt")   # 無 msigdbr 時：把 MSigDB *.gmt（symbols）放在 00_metadata/gmt/
for (g in list.files(gmt_dir, "\\.gmt$", full.names = TRUE)) {
  lines <- strsplit(readLines(g), "\t"); collections[[sub("\\.gmt$", "", basename(g))]] <- setNames(lapply(lines, function(x) harmonize_symbols(x[-(1:2)])), sapply(lines, `[`, 1))
}
sig <- fread(pp("metadata", "gene_signatures.csv")); collections$Custom <- split(harmonize_symbols(sig$gene), sig$signature)
collections <- collections[!sapply(collections, is.null)]
log_msg("Gene-set collections: ", paste(names(collections), lengths(collections), sep = "=", collapse = ", "))

# ---------- GSEA per ranked list ----------
rnks <- list.files(pp("bulk", "ranked_lists"), "\\.rnk$", full.names = TRUE)
gsea_all <- list()
for (r in rnks) {
  key <- sub("\\.rnk$", "", basename(r)); x <- fread(r, header = FALSE)
  stats <- setNames(x$V2, harmonize_symbols(x$V1)); stats <- stats[!duplicated(names(stats)) & is.finite(stats)]
  for (cn in intersect(c("Hallmark", "Reactome", "GOBP", "KEGG", "Custom"), names(collections))) {
    gs <- collections[[cn]]
    res <- if (has("fgsea")) {
      set.seed(CFG$seed)
      z <- fgsea::fgsea(gs, stats, minSize = 5, maxSize = 500, eps = 0)
      data.table(pathway = z$pathway, NES = z$NES, pval = z$pval, padj = z$padj, size = z$size,
                 leadingEdge = sapply(z$leadingEdge, paste, collapse = ";"), method = "fgsea")
    } else {
      idx <- lapply(gs, function(g) which(names(stats) %in% g)); idx <- idx[lengths(idx) >= 5 & lengths(idx) <= 500]
      z <- cameraPR(stats, idx)
      data.table(pathway = rownames(z), NES = ifelse(z$Direction == "Up", 1, -1), pval = z$PValue, padj = z$FDR,
                 size = z$NGenes, leadingEdge = NA, method = "cameraPR (fallback)")
    }
    res[, `:=`(key = key, collection = cn)]
    gsea_all[[paste(key, cn)]] <- res
  }
}
gsea <- rbindlist(gsea_all, fill = TRUE)
if (nrow(gsea)) {
  gsea[, c("dataset", "layer", "comparison") := tstrsplit(key, "__")]
  gsea[, priority_term := grepl(paste(PRIORITY_TERMS, collapse = "|"), toupper(pathway))]
  safe_fwrite(gsea, pp("pathway", "GSEA_all.csv"))
  # Fig 10 GSEA dot plot：Hallmark，pos_vs_neg，所有資料集 × layer
  d <- gsea[collection == "Hallmark" & comparison == "pos_vs_neg"]
  if (nrow(d)) {
    keep <- d[, .(best = min(padj, na.rm = TRUE)), by = pathway][order(best)][1:min(30, .N), pathway]
    d <- d[pathway %in% keep]; d[, pathway := sub("^HALLMARK_", "", pathway)]
    p <- ggplot(d, aes(paste(dataset, layer, sep = "\n"), reorder(pathway, NES), color = NES, size = -log10(padj + 1e-10))) +
      geom_point() + scale_color_gradient2(low = "#2E86C1", high = "#C0392B") +
      labs(x = NULL, y = NULL, size = "-log10 FDR", title = "Hallmark GSEA: HPV⁺ vs HPV⁻ (full ranked list)") +
      theme_pub() + theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 7))
    save_fig(p, "Fig10_GSEA_Hallmark_dotplot", 9, 8, subdir = "pathway")
  }
}

# ---------- ORA on meta-analysis genes ----------
metas <- list.files(pdir("meta"), "^meta_.*\\.csv$", full.names = TRUE)
for (mf in metas) {
  tag <- sub("^meta_|\\.csv$", "", basename(mf)); m <- fread(mf)
  univ <- m$gene
  up <- m[meta_call == "HPV_up_consistent", gene]; dn <- m[meta_call == "HPV_down_consistent", gene]
  if (has("clusterProfiler") && has("org.Hs.eg.db")) {
    eg <- function(g) suppressMessages(clusterProfiler::bitr(g, "SYMBOL", "ENTREZID", org.Hs.eg.db::org.Hs.eg.db)$ENTREZID)
    for (dir in c("up", "down")) {
      g <- if (dir == "up") up else dn; if (length(g) < 10) next
      go <- clusterProfiler::enrichGO(g, org.Hs.eg.db::org.Hs.eg.db, keyType = "SYMBOL", ont = "BP", universe = univ)
      safe_fwrite(as.data.table(as.data.frame(go)), pp("pathway", paste0("ORA_GOBP_", dir, "_", tag, ".csv")))
      kk <- tryCatch(clusterProfiler::enrichKEGG(eg(g), universe = eg(univ)), error = function(e) NULL)   # 需網路（KEGG REST）
      if (!is.null(kk)) safe_fwrite(as.data.table(as.data.frame(kk)), pp("pathway", paste0("ORA_KEGG_", dir, "_", tag, ".csv")))
      if (has("ReactomePA")) {
        ra <- ReactomePA::enrichPathway(eg(g), universe = eg(univ))
        safe_fwrite(as.data.table(as.data.frame(ra)), pp("pathway", paste0("ORA_Reactome_", dir, "_", tag, ".csv")))
      }
    }
  } else if (length(collections)) {   # fallback：超幾何 ORA
    ora <- function(g, gs) rbindlist(lapply(names(gs), function(n) { s <- intersect(gs[[n]], univ); k <- length(intersect(g, s))
      data.table(term = n, overlap = k, set_size = length(s), P = phyper(k - 1, length(s), length(univ) - length(s), length(g), lower.tail = FALSE)) }))
    for (dir in c("up", "down")) { g <- if (dir == "up") up else dn; if (length(g) < 10) next
      for (cn in intersect(c("GOBP", "Reactome", "KEGG", "Hallmark"), names(collections))) {
        o <- ora(g, collections[[cn]])[set_size >= 5][, FDR := p.adjust(P, "BH")][order(P)]
        safe_fwrite(o, pp("pathway", paste0("ORA_", cn, "_", dir, "_", tag, "_hypergeom.csv"))) } }
  }
  # ---------- PPI ----------
  if (has("STRINGdb")) {
    cand <- unique(c(CORE, head(m[meta_call != "NS"][order(meta_P), gene], 150)))
    sdb <- tryCatch(STRINGdb::STRINGdb$new(version = "12.0", species = 9606, score_threshold = 700, input_directory = pdir("raw", "STRING")),
                    error = function(e) NULL)
    if (!is.null(sdb)) {
      mp <- sdb$map(data.frame(gene = cand), "gene", removeUnmappedRows = TRUE)
      ed <- as.data.table(sdb$get_interactions(mp$STRING_id))
      ed <- merge(merge(ed, data.table(from = mp$STRING_id, g1 = mp$gene), by = "from"), data.table(to = mp$STRING_id, g2 = mp$gene), by = "to")
      safe_fwrite(unique(ed[, .(g1, g2, combined_score)]), pp("pathway", paste0("PPI_STRING_", tag, ".csv")))
      deg <- ed[, .N, by = g1][order(-N)]; setnames(deg, c("gene", "degree"))
      safe_fwrite(deg, pp("pathway", paste0("PPI_degree_", tag, ".csv")))   # 12_candidate_priority 使用 degree 作 pathway centrality
    }
  }
}

# ---------- TF activity / upstream regulator ----------
if (has("decoupleR") && length(rnks)) {
  net <- tryCatch(decoupleR::get_collectri(organism = "human", split_complexes = FALSE), error = function(e) NULL)
  if (!is.null(net)) {
    tf <- rbindlist(lapply(rnks, function(r) {
      x <- fread(r, header = FALSE); mat <- matrix(x$V2, dimnames = list(harmonize_symbols(x$V1), "t"))
      mat <- mat[!duplicated(rownames(mat)), , drop = FALSE]
      a <- decoupleR::run_ulm(mat, net, .source = "source", .target = "target", .mor = "mor", minsize = 5)
      as.data.table(a)[, key := sub("\\.rnk$", "", basename(r))]
    }))
    tf[, FDR := p.adjust(p_value, "BH"), by = key]
    safe_fwrite(tf, pp("pathway", "TF_activity_decoupleR_CollecTRI.csv"))
  }
} else if ("TFT_GTRD" %in% names(collections) && has("fgsea")) {
  tfr <- rbindlist(lapply(rnks, function(r) { x <- fread(r, header = FALSE)
    st <- setNames(x$V2, harmonize_symbols(x$V1)); st <- st[!duplicated(names(st))]
    z <- fgsea::fgsea(collections$TFT_GTRD, st, minSize = 10, maxSize = 1000)
    data.table(key = sub("\\.rnk$", "", basename(r)), tf_set = z$pathway, NES = z$NES, padj = z$padj) }))
  safe_fwrite(tfr, pp("pathway", "TF_target_GSEA_GTRD.csv"))
}

# ---------- WGCNA（樣本數足夠者）----------
if (has("WGCNA")) {
  for (f in list.files(pdir("processed"), "_gene_expr\\.rds$", full.names = TRUE)) {
    gse <- sub("_gene_expr\\.rds$", "", basename(f)); obj <- readRDS(f)
    s <- obj$samples[sample_type == "tumor" & !is.na(hpv_binary) & !(qc_outlier %in% TRUE)]
    if (nrow(s) < 40) { log_msg("WGCNA 略過 ", gse, "（tumor n=", nrow(s), " < 40）"); next }
    ex <- obj$expr[, s$gsm]; ex <- ex[order(-apply(ex, 1, mad))[1:min(5000, nrow(ex))], ]
    datExpr <- t(ex)
    sft <- WGCNA::pickSoftThreshold(datExpr, powerVector = 1:20, verbose = 0)
    pw <- sft$powerEstimate; if (is.na(pw)) pw <- 6
    net <- tryCatch(WGCNA::blockwiseModules(datExpr, power = pw, TOMType = "signed", minModuleSize = 30, mergeCutHeight = 0.25,
                                   numericLabels = FALSE, verbose = 0, randomSeed = CFG$seed), error = function(e) NULL)
    if (is.null(net) || all(net$colors == "grey")) { log_msg("WGCNA ", gse, "：未偵測到非 grey module（或失敗），略過"); next }
    trait <- data.table(HPV = as.numeric(s$hpv_binary == "HPV_pos"),
                        oral_cavity = as.numeric(s$anatomic_site == "oral_cavity"))
    mt <- cor(net$MEs, trait, use = "p"); mp <- WGCNA::corPvalueStudent(mt, nrow(datExpr))
    safe_fwrite(data.table(module = rownames(mt), r_HPV = mt[, 1], P_HPV = mp[, 1], r_oral = mt[, 2], P_oral = mp[, 2]),
                pp("pathway", paste0("WGCNA_module_trait_", gse, ".csv")))
    mods <- data.table(gene = colnames(datExpr), module = net$colors)
    safe_fwrite(mods, pp("pathway", paste0("WGCNA_modules_", gse, ".csv")))
    log_msg("WGCNA ", gse, "：power=", pw, "；核心基因所在 module：",
            paste(mods[gene %in% CORE, paste(gene, module, sep = "=")], collapse = ", "))
  }
}
finish_script("08_enrichment_network")
