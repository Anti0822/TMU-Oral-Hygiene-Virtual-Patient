# HPV_OSCC_multiomics

HPV⁺ 與 HPV⁻ 口腔／口咽鱗狀細胞癌之基因表徵與分子機制差異——可重現的 R 分析專案。
核心基因：**OGT、OGA（舊符號 MGEA5）、MTHFD2、CORO1A、CD274（PD-L1）**。

完整研究設計、資料集稽核與研究計畫：**[`docs/Study_Report_PartA-G.md`](docs/Study_Report_PartA-G.md)**
資料集稽核表：**[`00_metadata/dataset_audit_table.csv`](00_metadata/dataset_audit_table.csv)**

## 目前狀態（請先讀）

| 項目 | 狀態 |
|---|---|
| Dataset audit table | 已建立（20 列）；因建置環境無法連線 NCBI，多數欄位來自二手來源，已逐格標示「尚待確認」與來源 URL |
| GSM 層級對照 | **尚未產生**：需在可連線 NCBI 的電腦執行 `02_gsm_sample_audit.R`（本專案沒有任何人工填入或推測的 GSM） |
| R 程式碼 | 完成（01–13、run_all）；已用模擬資料在 R 4.3.3 / Bioconductor 3.18 完整執行 02–09、11–13 |
| 真實資料分析結果 | **尚無**：`03_…`～`10_tables/` 目前是空的 |

## 快速開始

```bash
cd HPV_OSCC_multiomics
Rscript scripts/00_setup_packages.R          # 安裝套件（失敗者會列出替代方案）
Rscript scripts/run_all.R                    # Stage 1：下載 + GSM 稽核
#  → 檢查 00_metadata/gsm_mapping/*，人工確認後另存 *_samples_curated.csv
Rscript scripts/run_all.R --analysis         # Stage 2：前處理 → DEG → meta → pathway → immune → single-cell → survival → CPS → 圖
```

單獨執行某步驟：`Rscript scripts/05_bulk_DEG.R GSE65858 GSE3292`

驗證流程（在專案副本中，不會污染正式資料夾）：
```bash
cp -r HPV_OSCC_multiomics /tmp/sim && cd /tmp/sim && Rscript scripts/99_simulated_pipeline_test.R
```

## 目錄

| 資料夾 | 內容 |
|---|---|
| `config/config.yaml` | seed、路徑、DEG 閾值、核心基因與別名、資料集清單 |
| `00_metadata/` | audit table、gene signatures（含來源）、druggability 註記、GSM mapping、exclusion log、欄位覆寫 |
| `01_raw_data/` | GEO 下載（git 不追蹤大型檔案） |
| `02_processed_data/` | 每資料集 gene-level 矩陣＋樣本表、QC |
| `03_bulk_analysis/` | 每資料集 × 層 × 比較之完整 DEG 表與 `.rnk` |
| `04_meta_analysis/` | meta-analysis、重現基因、rank-rank |
| `05_pathway_analysis/` | GSVA/ssGSEA、GSEA、ORA、TF、PPI、WGCNA |
| `06_immune_analysis/` | deconvolution 結果 |
| `07_single_cell/` | Seurat 物件、pseudobulk、CellChat |
| `08_survival/` | （存活表輸出至 10_tables） |
| `09_figures/` | 所有圖（PDF＋SVG＋600 dpi PNG） |
| `10_tables/` | 論文用表格 |
| `results/` | logs、sessionInfo |

## 設計上的防呆

- HPV evidence level A–E；**p16-only 不會被歸為 HPV-active**，只進獨立的 `p16_surrogate_pos_vs_neg` 比較
- `tongue` 未註明 oral/base 者標為 `tongue_ambiguous`，只進 sensitivity
- 不跨平台合併 raw expression；先各自分析再 meta-analysis（Hedges' g）
- 不對 raw counts 做 t-test；RNA-seq 用 DESeq2（＋voom 交叉確認）
- single-cell 以 patient 為單位（組成、pseudobulk、score），不做 cell-level DEG
- CORO1A／CD274 bulk 相關做 tumor-purity partial correlation，且需 single-cell 佐證細胞來源
- OGT−OGA ratio 僅為探索性 mRNA 指標

## 套件替代方案

見 `scripts/00_setup_packages.R` 的 `ALTERNATIVES`：immunedeconv → MCPcounter＋estimate＋GSVA markers；CellChat → LIANA；
inferCNV → copykat；msigdbr → 手動 GMT（放在 `00_metadata/gmt/`）；clusterProfiler → limma::goana/kegga 或內建超幾何 ORA；
CIBERSORTx 需授權，不納入自動流程。
