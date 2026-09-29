# ============================================================
# 00_setup_packages.R — 安裝所有需要的套件（CRAN / Bioconductor / GitHub）
# 建議 R >= 4.3、Bioconductor >= 3.18。若可用 renv，最後執行 renv::snapshot() 鎖定版本。
# 無法安裝時的替代方案列在 ALTERNATIVES（亦見 README）。
# ============================================================
options(repos = c(CRAN = "https://cloud.r-project.org"))
if (!requireNamespace("BiocManager", quietly = TRUE)) install.packages("BiocManager")

cran <- c("yaml", "data.table", "ggplot2", "ggrepel", "patchwork", "scales", "svglite", "ragg",
          "metafor", "RobustRankAggreg", "survival", "survminer", "rms", "ppcor", "UpSetR",
          "pheatmap", "WGCNA", "Seurat", "harmony", "msigdbr", "jsonlite", "R.utils", "Matrix",
          "ggalluvial", "DiagrammeR", "DiagrammeRsvg", "rsvg", "remotes", "UCSCXenaTools")
bioc <- c("GEOquery", "Biobase", "limma", "affy", "oligo", "arrayQualityMetrics", "DESeq2",
          "edgeR", "tximport", "sva", "clusterProfiler", "ReactomePA", "org.Hs.eg.db",
          "GSVA", "singscore", "AUCell", "fgsea", "ComplexHeatmap", "SingleR", "celldex",
          "scDblFinder", "infercnv", "TCGAbiolinks", "decoupleR", "OmnipathR",
          "hgu133plus2.db", "illuminaHumanv4.db", "hugene10sttranscriptcluster.db", "STRINGdb",
          "SummarizedExperiment", "scuttle")
github <- c("omnideconv/immunedeconv", "jinworks/CellChat", "saeyslab/nichenetr",
            "ebecht/MCPcounter/Source", "IOBR/IOBR", "icbi-lab/quanTIseq")
# ESTIMATE 由 R-Forge 提供：
# install.packages("estimate", repos = "http://r-forge.r-project.org", dependencies = TRUE)

inst <- rownames(installed.packages())
miss_cran <- setdiff(cran, inst); if (length(miss_cran)) install.packages(miss_cran)
miss_bioc <- setdiff(bioc, inst); if (length(miss_bioc)) BiocManager::install(miss_bioc, update = FALSE, ask = FALSE)
for (g in github) {
  pkg <- basename(sub("/Source$", "", g))
  if (!pkg %in% inst) try(remotes::install_github(g, upgrade = "never"), silent = TRUE)
}

ALTERNATIVES <- list(
  immunedeconv   = "失敗時：MCPcounter（GitHub）＋ estimate（R-Forge）＋ GSVA 以 Bindea/Charoentong 細胞 signature 計分",
  CellChat       = "失敗時：LIANA（saezlab/liana）或 CellPhoneDB（Python）；NicheNet 失敗時用 LIANA 的 consensus",
  infercnv       = "失敗時（需 JAGS）：copykat（navinlabcode/copykat）或 SCEVAN",
  msigdbr        = "失敗時：從 MSigDB 下載 h.all.v2023.2.Hs.symbols.gmt，用 fgsea::gmtPathways() 讀取",
  clusterProfiler= "失敗時：limma::goana()/kegga() 或 fgsea + GO/Reactome GMT",
  arrayQualityMetrics = "失敗時：使用 03 腳本內建的 PCA、sample-sample correlation、NUSE/RLE（affyPLM）",
  CIBERSORTx     = "需學術授權與網站上傳，不納入自動流程；可用 immunedeconv 的 cibersort_abs 需自行提供 CIBERSORT.R 與 LM22"
)
ok <- sapply(c(cran, bioc, basename(sub("/Source$", "", github))), requireNamespace, quietly = TRUE)
print(table(ok))
if (any(!ok)) {
  message("未安裝成功：", paste(names(ok)[!ok], collapse = ", "))
  message("替代方案："); print(ALTERNATIVES)
}
writeLines(capture.output(sessionInfo()), "results/00_setup_sessionInfo.txt")
