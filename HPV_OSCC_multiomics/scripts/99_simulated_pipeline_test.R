# ============================================================
# 99_simulated_pipeline_test.R — 以「模擬資料」驗證整條流程可執行（不產生任何研究結論）
#
# 建立 3 個仿 GEO microarray 資料集（含 characteristics、HPV DNA/RNA/p16、site、存活）與 1 個 RNA-seq counts 資料集，
# 內建已知效應（MTHFD2、OGT 在 HPV⁺ 上升；CORO1A 隨免疫浸潤上升），用來檢查：
#   02 稽核能正確判定 HPV evidence level / site；05 能找回植入效應；06/07/09/11/12/13 可正常產出。
# 用法（請在專案「副本」中執行，避免模擬檔混入正式資料夾）：
#   cp -r HPV_OSCC_multiomics /tmp/sim && cd /tmp/sim && Rscript scripts/99_simulated_pipeline_test.R
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
SCRIPTS <- .src()
source(file.path(SCRIPTS, "utils.R"))
suppressPackageStartupMessages(library(Biobase))
if (file.exists(file.path(PROJ, ".git")) || file.exists(file.path(dirname(PROJ), ".git")))
  stop("請在專案副本中執行本測試（偵測到 .git）")
set.seed(1)

genes <- c(harmonize_symbols(CFG$core_genes), unique(harmonize_symbols(fread(pp("metadata", "gene_signatures.csv"))$gene)),
           sprintf("GENE%04d", 1:2500))
genes <- unique(genes)
make_ds <- function(gse, n, site_mix, rna_info = TRUE, survival = FALSE, platform = "GPL570") {
  hpv <- rbinom(n, 1, 0.45)
  active <- ifelse(hpv == 1, rbinom(n, 1, 0.75), 0)
  site <- sample(names(site_mix), n, TRUE, prob = site_mix)
  immune <- rnorm(n)
  X <- matrix(rnorm(length(genes) * n, 8, 1), length(genes), n, dimnames = list(NULL, sprintf("%s_S%03d", gse, 1:n)))
  gi <- function(g) which(genes == g)
  X[gi("MTHFD2"), ] <- X[gi("MTHFD2"), ] + 1.2 * active + 0.4 * hpv
  X[gi("OGT"), ] <- X[gi("OGT"), ] + 0.8 * active
  X[gi("CD274"), ] <- X[gi("CD274"), ] + 0.6 * hpv + 0.7 * immune
  X[gi("CORO1A"), ] <- X[gi("CORO1A"), ] + 1.0 * immune
  for (g in c("CD8A", "CD8B", "PRF1", "GZMB", "NKG7", "CD3D", "CD3E")) if (length(gi(g))) X[gi(g), ] <- X[gi(g), ] + immune
  for (g in c("MCM2", "E2F1", "RRM2", "CDKN2A")) if (length(gi(g))) X[gi(g), ] <- X[gi(g), ] + 1.5 * active
  probes <- sprintf("P%05d", seq_along(genes)); rownames(X) <- probes
  gsm <- sprintf("GSM9%s%03d", substr(gse, 4, 8), 1:n)
  colnames(X) <- gsm
  site_txt <- c(oral = "oral tongue", fom = "floor of mouth", oro = "tonsil", bot = "base of tongue", lar = "larynx")[site]
  pd <- data.frame(title = paste0("tumor_", 1:n), geo_accession = gsm, source_name_ch1 = "HNSCC primary tumor",
                   platform_id = platform, row.names = gsm, stringsAsFactors = FALSE)
  pd[["tumor site:ch1"]] <- site_txt
  if (rna_info) {
    pd[["hpv16 dna:ch1"]] <- ifelse(hpv == 1, "positive", "negative")
    pd[["hpv16 rna (e6/e7):ch1"]] <- ifelse(active == 1, "positive", "negative")
  } else pd[["p16 ihc:ch1"]] <- ifelse(hpv == 1, "positive", "negative")
  pd[["smoking:ch1"]] <- sample(c("never", "current", "former"), n, TRUE)
  pd[["gender:ch1"]] <- sample(c("male", "female"), n, TRUE)
  pd[["age:ch1"]] <- round(rnorm(n, 60, 9))
  pd[["uicc stage:ch1"]] <- sample(c("I", "II", "III", "IV"), n, TRUE)
  pd[["n stage:ch1"]] <- sample(c("N0", "N1", "N2"), n, TRUE)
  if (survival) {
    haz <- exp(-0.9 * hpv + 0.3 * scale(X[gi("MTHFD2"), ])[, 1])
    tt <- rexp(n, 0.02 * haz); ct <- runif(n, 20, 80)
    pd[["os time (months):ch1"]] <- round(pmin(tt, ct), 1); pd[["os event:ch1"]] <- ifelse(tt <= ct, "dead", "alive")
  }
  fd <- data.frame(ID = probes, `Gene Symbol` = ifelse(genes == "OGA", "MGEA5", genes), row.names = probes, check.names = FALSE)
  es <- ExpressionSet(2^X, phenoData = AnnotatedDataFrame(pd), featureData = AnnotatedDataFrame(fd))
  d <- pdir("raw", gse); saveRDS(setNames(list(es), paste0(gse, "_series_matrix.txt.gz")), file.path(d, paste0(gse, "_eset_list.rds")))
  pr <- as.data.table(pd, keep.rownames = "gsm_rowname"); pr[, series_matrix_file := "sim"]
  fwrite(pr, file.path(d, paste0(gse, "_pheno_raw.csv")))
  invisible(list(X = X, pd = pd))
}
make_ds("GSE90001", 60, c(oral = .5, fom = .1, oro = .3, lar = .1), rna_info = TRUE)
make_ds("GSE90002", 40, c(oral = .6, oro = .4), rna_info = FALSE)
make_ds("GSE65858", 150, c(oral = .35, oro = .4, lar = .25), rna_info = TRUE, survival = TRUE, platform = "GPL10558")
# RNA-seq counts dataset
sim_rs <- make_ds("GSE90003", 36, c(oral = .5, oro = .5), rna_info = TRUE)
cnt <- matrix(rnbinom(length(sim_rs$X), mu = 2^(sim_rs$X - 3), size = 10), nrow(sim_rs$X), dimnames = list(genes, colnames(sim_rs$X)))
fwrite(data.table(gene = genes, cnt), file.path(pdir("raw", "GSE90003"), "GSE90003_raw_counts.txt.gz"))
es_list <- readRDS(file.path(pdir("raw", "GSE90003"), "GSE90003_eset_list.rds"))
es_list[[1]] <- es_list[[1]][0, ]   # RNA-seq series matrix 無表現值
saveRDS(es_list, file.path(pdir("raw", "GSE90003"), "GSE90003_eset_list.rds"))

CFG_sim <- CFG
CFG_sim$datasets$bulk <- list(list(id = "GSE90001", type = "microarray"), list(id = "GSE90002", type = "microarray"),
                              list(id = "GSE65858", type = "microarray"), list(id = "GSE90003", type = "rnaseq_counts"))
CFG_sim$datasets$cellline <- list()
yaml::write_yaml(CFG_sim, file.path(PROJ, "config", "config.yaml"))

run <- function(script, args = character()) {
  cmd <- paste("Rscript", shQuote(file.path(SCRIPTS, script)), paste(args, collapse = " "))
  message("\n>>> ", cmd); st <- system(cmd); if (st != 0) stop(script, " 失敗（exit ", st, "）")
}
run("02_gsm_sample_audit.R")
run("03_preprocess_microarray.R", c("GSE90001", "GSE90002", "GSE65858"))
run("04_preprocess_rnaseq.R", "GSE90003")
run("05_bulk_DEG.R"); run("06_meta_analysis.R"); run("07_pathway_scores.R"); run("08_enrichment_network.R")
run("09_immune_deconvolution.R"); run("11_survival.R"); run("12_candidate_priority.R"); run("13_summary_figures.R")

# ---------- 驗證植入效應是否被找回 ----------
core <- fread(pp("tables", "Table_3_core_genes_per_dataset.csv"))
chk <- core[comparison == "active_vs_neg" & layer == "sensitivity" & gene_display %in% c("MTHFD2", "OGT")]
print(chk[, .(dataset, gene_display, logFC, adj.P.Val)])
stopifnot(all(chk$logFC > 0))
aud <- fread(pp("metadata", "gsm_mapping", "GSE90002_samples_auto.csv"))
stopifnot(all(aud$hpv_evidence_level == "D"), !any(aud$hpv_group_detail == "HPV_active"))   # p16-only 不可為 active
aud1 <- fread(pp("metadata", "gsm_mapping", "GSE90001_samples_auto.csv"))
stopifnot(all(aud1[anatomic_site == "oropharynx", grepl("tonsil|base of tongue", site_raw)]))
message("\n✔ 模擬測試通過：流程可執行、p16-only 未被誤判為 HPV-active、植入之 MTHFD2/OGT 效應方向正確")
