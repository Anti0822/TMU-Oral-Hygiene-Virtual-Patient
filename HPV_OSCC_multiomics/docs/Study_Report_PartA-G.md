# HPV 狀態相關之代謝、O-GlcNAc 與免疫逃逸程式：口腔與口咽鱗狀細胞癌之多資料集研究
## Study Report（Part A–G）

> **本文件的證據分級標記**
> - 【已知證據】＝已發表文獻內容（附來源；PMID 未能在本環境核實者標示「尚待確認」）
> - 【分析結果】＝本專案程式執行後才會產生（目前**尚未**以真實資料執行，見下方「執行狀態」）
> - 【研究假說】＝待驗證，不可寫成已證實因果
>
> **執行狀態（重要）**：本專案在雲端容器中建立。該環境的網路政策封鎖了 `ncbi.nlm.nih.gov`、`ebi.ac.uk`、CRAN 與 Bioconductor，
> 因此**無法**在此下載 GEO 資料或逐一核對 GSM。資料集資訊僅能透過 WebSearch 取得二手摘要，已逐格標示來源與「尚待確認」。
> 所有 R 程式碼已用**模擬資料**完整執行過（`scripts/99_simulated_pipeline_test.R`），證明流程可跑、HPV 分級規則正確；
> 但**本報告中沒有任何真實資料的分析數字**。請在可連線的電腦執行 `scripts/run_all.R` 後，依產生的表格更新本報告。

> **基因符號更正**：HGNC 現行核准符號為 **OGA**（O-GlcNAcase）；**MGEA5 是舊符號**（多數舊 microarray 註解仍使用）。
> 程式中統一轉成 `OGA`，圖表顯示為 `OGA (MGEA5)`，避免因符號不一致而漏抓基因。

---

## Part A：Dataset audit

### A1. 疾病與部位定義（全專案一致）

| 類別 | 定義 | 程式中的標籤 |
|---|---|---|
| Oral cavity SCC（OSCC） | oral/mobile tongue（前 2/3）、floor of mouth、buccal mucosa、gingiva/alveolar ridge、hard palate、retromolar trigone、lip | `oral_cavity` |
| Oropharyngeal SCC（OPSCC） | tonsil、base of tongue、soft palate、uvula、oropharyngeal wall、vallecula | `oropharynx` |
| Mixed HNSCC | 含 larynx、hypopharynx 或部位不明 | `larynx`／`hypopharynx`／`unknown` |
| 「tongue」未註明 | 不可自行歸類 | `tongue_ambiguous`（只進 sensitivity，需人工核對） |
| Cervical 及其他 HPV 相關癌 | 非頭頸部 | `cervix` → 排除 |

### A2. HPV evidence level（程式規則：`scripts/utils.R::classify_hpv_evidence`）

| Level | 定義 | 分組 |
|---|---|---|
| A | HPV DNA⁺ 且 E6/E7 RNA⁺（或 transcriptionally active 證據） | `HPV_active` |
| B | HPV RNA⁺（無 DNA 資訊） | `HPV_active` |
| C | HPV DNA⁺，RNA 陰性或未檢測 | RNA 陰性 → `HPV_inactive`；未測 → `HPV_pos_DNA_only` |
| D | 僅 p16 | `p16_pos_only`／`p16_neg_only` → **只進獨立的 `p16_surrogate_pos_vs_neg` 比較** |
| E | 定義不明或僅作者分組 | `HPV_pos_author`／`HPV_neg_author` |

HPV 陰性樣本亦依判定所用檢測給 level（DNA⁻ 且 RNA⁻ → A；僅 RNA⁻ → B；僅 DNA⁻ → C）。
模擬測試已驗證：p16-only 樣本 **不會**被歸為 HPV-active。

### A3. 完整 Dataset Audit Table

完整 28 欄表格（含 24 個必要欄位、驗證狀態與來源 URL）：**`00_metadata/dataset_audit_table.csv`**。以下為摘要：

| Accession | 類型 | 平台 | HPV⁺/HPV⁻（來源） | HPV 方法／預期 level | 部位 | 建議用途 | 決定 |
|---|---|---|---|---|---|---|---|
| GSE72536 | Bulk RNA-seq | Illumina HiSeq 2000 | 論文分析 10/13（TIL-high/med） | 待確認（C 或 D） | 以 OP 為主；待確認 | Discovery（OPSCC/sensitivity） | Conditional |
| GSE55544 | Microarray | **平台資訊互相矛盾**（Agilent G3 v2 vs Affy U133 Plus 2.0） | 二手引用 11/8 | 待確認（E） | "oral and oropharyngeal" | Discovery（若 GSM 可分部位） | Conditional |
| GSE55542 | 待確認 | 待確認 | 待確認 | 待確認 | 待確認 | 確認是否為 SuperSeries | Audit only |
| GSE3292 | Microarray | GPL570 | 8/28 | 待確認（C？） | Mixed | Discovery（sensitivity） | Include |
| GSE6791 | Microarray（LCM） | GPL570 | HNC 42 例中 HPV⁺/⁻ 待 GSM 核對 | HPV PCR 分型（C） | Mixed；另含 cervix/normal | Discovery（僅 HN tumor） | Include（subset） |
| GSE40774 | Microarray | 待確認 | 待確認 | 待確認 | 待確認 | — | Pending |
| **GSE65858** | Microarray | GPL10558（HumanHT-12 v4） | 270 tumors；分組待核 | **HPV16 DNA + RNA（A）** | OC/OP/HP/LX | Validation、survival、active vs inactive、WGCNA | **Include（核心）** |
| GSE74927（新增） | Bulk RNA-seq | Illumina | 84 HNSCC | RNA reads／integration（A/B） | Mixed | HPV-active、integration × CD274 | Conditional |
| GSE112026 | Bulk RNA-seq | HiSeq 2500 | 46 HPV⁺ / 0 | 待確認 | OP | HPV⁺ subgroup | Supplementary |
| GSE40020 | Microarray | 待確認 | 19 HPV⁺ / 0 | HPV16 E7 DNA+RNA（A） | 待確認 | HPV⁺ 治療反應 | Supplementary |
| GSE41613 | Microarray | GPL570（待確認） | 0 / 全部 | — | Oral cavity | HPV⁻ OSCC 存活驗證 | Supplementary |
| GSE184616、GSE162519 | 待確認 | 待確認 | 待確認 | 待確認 | 待確認 | — | Pending |
| **GSE164690** | scRNA-seq | 10x（待確認） | 病人數待確認 | 待確認（可能 p16 → D） | 待確認 | **主要 single-cell** | Include |
| GSE139324 | scRNA-seq（CD45⁺） | 10x | 8/18 patients | 待確認 | Mixed | 免疫細胞比較（無腫瘤細胞） | Include（immune） |
| GSE182227（新增） | scRNA-seq | 10x | 11/5 tumors | 待確認 | OPSCC | OPSCC malignant cell HPV 差異 | Include（secondary sc） |
| GSE173468 | scRNA-seq | 待確認 | HPV 未知 | — | 轉移灶 | — | Pending |
| GSE122512 | 待確認 | 待確認 | 待確認 | — | — | 二手描述不一致 | Pending |
| GSE62027 | Cell lines | 待確認 | HPV⁺：93VU147T、UM-SCC-47、UPCI:SCC090；HPV⁻：SCC61、SCC25、SQ20B；+HaCaT | — | — | 細胞株基線（含 SCC47） | Include（reference） |
| TCGA-HNSC | Bulk RNA-seq | Illumina | 2015 論文 279 例中 36 HPV⁺（>1000 E6/E7 reads） | RNA（B）；臨床 p16/ISH（D/C） | 以 OC 為主 | Oral cavity 存活驗證 | Include（clinical） |

**各資料集來源與原始論文**：見 `00_metadata/dataset_audit_table.csv` 的 `publication_PMID_DOI` 與 `source_urls` 欄。已可確認之 DOI／PMID：
- GSE3292：Slebos et al., *Clin Cancer Res* 2006;12(3):701，DOI 10.1158/1078-0432.CCR-05-2017
- GSE6791：Pyeon et al., *Cancer Res* 2007;67(10):4605，DOI 10.1158/0008-5472.CAN-06-3619（PMC2858285）
- GSE74927：Koneva et al., *Mol Cancer Res* 2018;16(1):90，PMID 28928286（PMC5752568）
- GSE139324：Cillo et al., *Immunity* 2020，PMID 31924475
- TCGA-HNSC：TCGA Network, *Nature* 2015;517:576，DOI 10.1038/nature14129
- GSE72536：Wood et al., *Oncotarget* 2016（PMC5302866；PMID 尚待確認）
- GSE65858、GSE164690、GSE182227、GSE41613、GSE112026、GSE40020：作者與期刊見表格，PMID 尚待確認

### A4. GSM sample mapping

**本環境無法取得 GSM 清單，因此沒有提供任何 GSM 編號**（避免捏造）。每個 GSM 的 HPV group、anatomic site、sample type 與臨床資料
由 `scripts/02_gsm_sample_audit.R` 從 GEO characteristics 自動產生，輸出至 `00_metadata/gsm_mapping/`（說明見 `00_metadata/gsm_mapping_README.md`）。

### A5. 為何完整 series 與既往分析 subset 數量不同（GSE72536：10/4；GSE55544：11/8）

- **GSE72536**：原始論文分析的是經 **TIL 密度篩選**的 23 例（10 HPV⁺／13 HPV⁻）。您既往的 10/4 比論文的 13 例 HPV⁻ 少 9 例，
  最可能原因是**部位限制**（只保留 oropharynx，HPV⁻ 口咽癌本來就少）或品質篩選。此為推論，**尚待確認**。
  `02_gsm_sample_audit.R` 會輸出 `subset_discrepancy_report.txt`，分別計算「只取 oral cavity」與「只取 oropharynx」的 HPV⁺/⁻ 數，檢查哪一種篩選能重現 10/4。
- **GSE55544**：二手文獻引用 11/8，平台資訊互相矛盾，且同系列 GSE55543 是「HPV⁻ OPSCC 非裔 vs 歐裔」比較、GSE55542 可能是 SuperSeries。
  **必須避免把 GSE55542 與 GSE55544 當成兩個獨立資料集**（樣本可能重疊）。差異原因待 GSM 核對。

### A6. 建議納入與排除

- **納入（bulk DEG）**：GSE65858、GSE3292、GSE6791（僅 HN tumor）、TCGA-HNSC；條件納入：GSE72536、GSE55544、GSE74927（待 GSM 稽核）
- **只作 subgroup／臨床支持**：GSE112026、GSE40020（只有 HPV⁺）、GSE41613（只有 HPV⁻）
- **Single-cell**：GSE164690（主要）、GSE182227（OPSCC）、GSE139324（僅免疫細胞）
- **Cell line**：GSE62027
- **待稽核**：GSE40774、GSE55542、GSE184616、GSE162519、GSE173468、GSE122512

---

## Part B：Recommended study design

**研究題目的建議**：以目前公開資料，**具 Level A/B HPV 證據的 HPV⁺ oral cavity 樣本預期很少**（TCGA 中 HPV⁺ 以口咽為主）。
在 02 稽核確認 oral cavity HPV⁺（Level A/B）至少每組 ≥ 10 例之前，**建議採用**：
“HPV status-associated metabolic, O-GlcNAc and immune-escape programs in oral and oropharyngeal squamous cell carcinoma”

| 角色 | Cohort | 理由 |
|---|---|---|
| Primary cohort（oral cavity） | GSE65858 oral cavity subset、TCGA-HNSC oral cavity、其他資料集經 GSM 確認的 oral cavity | GSE65858 有 HPV16 DNA+RNA（Level A）；TCGA 有 RNA-based HPV |
| Discovery cohorts | GSE3292、GSE6791（HN）、GSE72536、GSE55544、GSE74927 | 各自獨立分析後再 meta-analysis |
| Validation cohorts | GSE65858（全部位＋active/inactive）、TCGA-HNSC | 大樣本、HPV 證據較強 |
| Single-cell cohort | GSE164690（主）、GSE182227（OPSCC malignant）、GSE139324（immune） | 回答 CORO1A／CD274 細胞來源 |
| Cell-line cohort | GSE62027（公開）＋自有 SCC1、SCC6（HPV⁻）、SCC47、SCC104（HPV⁺） | 請以 Cellosaurus 核對各株原發部位與 HPV 型別，並做 STR 驗證與 HPV16 E6/E7 qPCR |
| Clinical survival cohort | GSE65858、TCGA-HNSC；GSE41613（HPV⁻ OSCC 內部驗證） | 有 OS/PFS |

---

## Part C：Analysis workflow（逐步流程與判讀原則）

| 步驟 | 腳本 | 內容 | 判讀原則 |
|---|---|---|---|
| 0 | `00_setup_packages.R` | 安裝 CRAN/Bioconductor/GitHub 套件；列出替代方案 | 用 `renv::snapshot()` 鎖版本 |
| 1 | `01_download_geo.R` | series matrix、phenoData、supplementary（`--raw`） | 下載失敗會記錄於 `geo_series_summary_auto.csv` |
| 2 | `02_gsm_sample_audit.R` | 逐 GSM 判定 HPV level、部位、樣本型態、臨床；exclusion log；核心基因可測性；subset 差異報告 | **先完成稽核與人工確認，才進入 DEG** |
| 3 | `03_preprocess_microarray.R` | CEL→RMA（背景校正＋quantile＋log2）；否則 series matrix（自動判斷 log2）＋quantile；probe→symbol（保留平均表現最高 probe；多基因 probe 排除）；PCA、hclust、outlier（相關性與 PCA 兩準則同時成立才排除）、batch（scan date 與 PC 的 R²） | 批次效應只有在 batch 與 HPV 不共線時才能納入模型；**不做跨平台合併** |
| 4 | `04_preprocess_rnaseq.R` | raw counts→filterByExpr＋TMM；非整數（FPKM/TPM）自動改走 limma-trend 並註明 | 不對 raw counts 做 t-test |
| 5 | `05_bulk_DEG.R` | 三層（primary/secondary/sensitivity）×比較（pos_vs_neg、active_vs_neg、active_vs_inactive、inactive_vs_neg、active_vs_nonactive、p16_surrogate）；模型 `~ HPV + [site] + smoking + sex + stage + batch`（共變項完整度≥90%才納入；不可估計時逐一移除）；microarray→limma（trend, robust）；counts→DESeq2＋voom 交叉確認 | reference＝HPV⁻；log2FC>0＝HPV⁺ 高；DEG：FDR<0.05 且 \|log2FC\|≥1；**輸出完整 ranked list**，含 95% CI、SE、nominal P、FDR、n、Hedges' g |
| 6 | `06_meta_analysis.R` | 方向一致性＋sign test；Hedges' g random-effects（DerSimonian–Laird，全基因）；核心基因 REML＋Knapp–Hartung forest；Stouffer（signed、√n 加權）、Fisher；RRA；≥2 資料集重現、全部共同；UpSet；rank-rank（Spearman＋RRHO 式 overlap） | I²≥75% 標為 `significant_but_heterogeneous`，不當作一致結果；**不以 Venn 交集選基因** |
| 7 | `07_pathway_scores.R` | GSVA＋ssGSEA（12 類 signature，組成見 `00_metadata/gene_signatures.csv`；另加 Hallmark）；OGT−OGA log2 ratio；limma 比較；核心基因 Spearman（HPV 分層）＋Fisher-z meta | OGT/OGA ratio 僅為探索性 mRNA 指標，**不等於 global O-GlcNAc** |
| 8 | `08_enrichment_network.R` | fgsea（Hallmark/Reactome/GO:BP/KEGG；fallback cameraPR）；ORA（clusterProfiler/ReactomePA）；TF 活性（decoupleR＋CollecTRI；fallback GTRD）；STRING PPI；WGCNA（tumor n≥40） | GSEA 一律用完整 ranked list |
| 9 | `09_immune_deconvolution.R` | immunedeconv（MCP-counter、EPIC、quanTIseq、xCell、ESTIMATE）＋GSVA marker 法；HPV 比較（Wilcoxon＋site 調整）；核心基因×免疫細胞 **purity-adjusted partial Spearman** | CORO1A／CD274 的 bulk 相關不可解釋為腫瘤內在機制 |
| 10 | `10_single_cell.R` | QC、scDblFinder、LogNormalize、Harmony（以 patient 整合）、marker＋SingleR 註解、inferCNV、patient-level 組成、**pseudobulk DESeq2**、核心基因 UMI 來源比例、patient-level pathway score、proliferating malignant 分析、CellChat；NicheNet 指引 | **不把單一細胞當獨立樣本**；CD45⁺-sorted 資料不能回答腫瘤細胞表現 |
| 11 | `11_survival.R` | KM（預先指定 median split）、univariate/multivariable Cox（EPV≥5）、HPV×gene interaction（LRT）、RCS（events≥50）、composite、pathway score、淋巴結轉移 logistic；PH 檢查 | 只描述 association |
| 12 | `12_candidate_priority.R` | Candidate Priority Score（11 分項加權，缺項重新正規化並輸出 completeness；I²≥75% 扣分） | CPS 是排序工具，不是統計檢定 |
| 13 | `13_summary_figures.R` | Fig 1、2、3、20 | Fig 20 全為虛線（假說） |

**多重檢定**：所有 per-gene、per-pathway、per-cell-type 檢定皆以 BH-FDR；存活分析在每個（cohort × endpoint × site × HPV）內校正。
**小樣本**：每組 < 3 不做 DEG；所有結果同時列出 log2FC、95% CI、nominal P、FDR、方向、n。

---

## Part D：Executable code

完整 R project 位於本資料夾，目錄結構符合規格（`00_metadata` … `10_tables`、`scripts`、`results`）。

- 每支腳本都包含：套件載入、固定 seed（`config.yaml: seed`）、輸入/輸出路徑（`pp()`／`pdir()`）、資料下載或讀取、metadata 整理、
  sample exclusion log（`00_metadata/sample_exclusion_log.csv`）、QC、統計模型、BH 校正、PDF/SVG/600-dpi PNG 輸出（`save_fig()`）、
  `sessionInfo`（`results/sessionInfo/`）與錯誤檢查（`assert_that()`、`tryCatch` 記錄至 `results/logs/`）。
- 執行：`Rscript scripts/00_setup_packages.R` → `Rscript scripts/run_all.R`（Stage 1 稽核）→ 人工確認 → `Rscript scripts/run_all.R --analysis`
- 驗證：`scripts/99_simulated_pipeline_test.R`（在專案副本中執行）。已在 R 4.3.3／Bioconductor 3.18 環境以模擬資料完整通過 02–13 步。
  10_single_cell 需真實 10x 資料，未在模擬測試中執行。

---

## Part E：Expected figures and tables

所有圖輸出於 `09_figures/`（PDF＋SVG＋600 dpi PNG），表輸出於 `10_tables/`。

| # | 研究目的 | 資料來源 | x / y | 統計方法 | 檔名 |
|---|---|---|---|---|---|
| 1 | 資料集篩選流程 | audit table、02 計數 | 流程圖 | — | `Fig1_dataset_selection_flowchart` |
| 2 | 資料集稽核 | `dataset_audit_table.csv` | 表格 | — | `Fig2_dataset_audit_table` |
| 3 | 樣本層級 HPV／部位註記 | 02 輸出 | 樣本（依資料集分欄）／註記列 | — | `Fig3_sample_annotation_heatmap` |
| 4 | 整體結構與 outlier | 03/04 | PC1 / PC2 | PCA；Mahalanobis | `QC/<GSE>_QC_PCA`、`_QC_hclust`；UMAP 見 Fig 15 |
| 5 | 各資料集 DEG | 05 | log2FC / −log10 P | limma／DESeq2 | `volcano/Fig5_volcano_<GSE>__<layer>__<cmp>` |
| 6 | Top DEG 模式 | 05 | 樣本 / 基因（z） | — | `heatmap/Fig6_topDEG_heatmap_*` |
| 7 | 核心基因分布 | 05 | 組別 / log2 表現 | 標註 log2FC、P、FDR | `core_boxplot/Fig7_coreBox_*` |
| 8 | 核心基因跨資料集一致性 | 06 | Hedges' g / 資料集 | REML＋Knapp–Hartung；I² | `meta/Fig8_core_forest_<layer>__<cmp>` |
| 9 | DEG 交集 | 06 | UpSet | — | `meta/Fig9_UpSet_*` |
| 10 | Hallmark GSEA | 08 | 資料集×層 / pathway（色=NES，大小=−log10 FDR） | fgsea | `pathway/Fig10_GSEA_Hallmark_dotplot` |
| 11 | Pathway score | 07 | 樣本 / signature；及資料集 / signature（t） | GSVA＋limma | `pathway/Fig11_pathwayHeatmap_*`、`Fig11b_*` |
| 12 | 核心基因共表現 | 07 | 基因 / 基因（ρ） | Spearman；Fisher-z meta（Table 6） | `pathway/Fig12_coreCor_*` |
| 13 | 免疫細胞比較 | 09 | HPV 組 / 估計值（多方法） | Wilcoxon、site 調整 lm | `immune/Fig13_immune_*` |
| 14 | Purity 調整相關 | 09 | 未調整 ρ / partial ρ | partial Spearman | `immune/Fig14_purity_adjusted_correlation` |
| 15 | Single-cell UMAP／組成 | 10 | UMAP；patient-level 比例 | Wilcoxon（patient） | `singlecell/Fig15_scUMAP`、`Fig15b_sc_composition` |
| 16 | 核心基因細胞定位 | 10 | 細胞型別 / 基因 | DotPlot、Violin | `singlecell/Fig16a_*`、`Fig16b_*` |
| 17 | 細胞間通訊 | 10 | network | CellChat | `singlecell/Fig17_CellChat_<HPV>` |
| 18 | 存活 | 11 | 月 / 存活率 | KM、log-rank | `survival/Fig18_KM_*` |
| 19 | 多變項 Cox | 11 | HR（log）/ 變項 | Cox | `survival/Fig19_multivariable_Cox_forest` |
| 20 | 工作模型（假說） | 綜合 | 示意圖（虛線） | — | `Fig20_proposed_mechanism` |

主要表格：`Table_3_core_genes_per_dataset`、`Table_4_core_gene_meta_*`、`Table_5_pathway_score_tests`、`Table_6_core_coexpression_meta`、
`Table_7_immune_HPV_comparison`、`Table_8_core_gene_immune_partial_correlation`、`Table_9–13_<scGSE>_*`、`Table_14_survival_all`、
`Table_15_lymph_node_association`、`Table_16_multivariable_cox_terms`、`Table_17_candidate_priority_score`、`Table_S2/S3/S4`。

---

## Part F：Candidate prioritization

> 以下為**分析前的預先指定假說排序**，依據是【已知生物學】與可驗證性；**真正排序請以執行後的 `Table_17_candidate_priority_score.csv` 為準**，
> 並逐項填入「supporting datasets / effect direction / cell-type origin」欄。任何一項若在資料中不成立，須如實降級。

| 排序 | 候選 | 預期方向（假說） | 需從資料確認的證據 | 細胞來源（待 single-cell） | 可藥性 | 必要驗證 |
|---|---|---|---|---|---|---|
| 1 | **MTHFD2** | HPV-active ↑（E7–RB–E2F／MYC 驅動增生相關代謝；假說） | 06 meta（active_vs_neg 與 pos_vs_neg）、07 one-carbon score、10 malignant pseudobulk | 預期 malignant（尤其 proliferating）；需 Table 9/13 確認 | 中：DS18561882、LY345899（工具化合物） | siMTHFD2／CRISPR；formate rescue；O-GlcNAc 與 PD-L1 讀值 |
| 2 | **OGT／OGA balance ＋ global O-GlcNAc** | HPV⁺ OGT/OGA ratio ↑（假說） | 06（OGT、OGA 分別）、07 HBP score 與 ratio | 多數細胞普遍表現；需確認 malignant 內差異 | 中：OSMI-1／OSMI-4（OGT）、Thiamet-G（OGA，機制工具） | RL2/CTD110.6 WB；OGT knockdown；Thiamet-G 反向操弄 |
| 3 | **CD274／PD-L1** | HPV⁺ ↑（部分可能由 IFN-γ 與免疫浸潤造成） | 06、07 IFN-γ score（需調整）、09 purity 調整 | **關鍵未知**：malignant vs macrophage（Table 9） | 高：已核准 anti-PD-1/PD-L1 | flow（表面）、WB（總量）、IFN-γ 刺激對照、EV PD-L1 |
| 4 | **MTHFD2–OGT–CD274 composite** | 同向共表現（假說） | Table 6 共表現 meta（HPV 分層）；Table 14 composite 存活 | 需確認三者是否在**同一群** malignant cells | 組合：MTHFD2 抑制劑＋anti-PD-L1 | 路徑順序需 perturbation＋rescue |
| 5 | **CORO1A（條件式）** | bulk ↑ 可能僅反映免疫浸潤 | 09 purity 調整後是否仍與 HPV 相關；10 UMI 來源 | **高度懷疑主要來自 T/NK/myeloid** | 低：無直接抑制劑 | 先確認 SCC47/SCC104 內源表現；若腫瘤細胞低表現，EV 假說改以 RAB27A 等 EV 基因為主 |

【已知證據】（供背景撰寫；PMID 須自行逐篇核對）
- HPV⁺ HNSCC 具較佳預後，且免疫反應相關表現主要在口咽（Chakravarthy et al., *J Clin Oncol* 2016；見 WebSearch 結果）。
- HPV 整合在 HNSCC 中與免疫訊號及存活相關，CD274 為論文報告的 recurrent integration 位點之一（Koneva et al., *Mol Cancer Res* 2018，PMID 28928286）。
- Exosomal PD-L1 可抑制抗腫瘤免疫（Chen et al., *Nature* 2018；Poggio et al., *Cell* 2019；HNSCC：Theodoraki et al., *Clin Cancer Res* 2018）——PMID 尚待確認。
- MTHFD2 抑制劑：DS18561882（Kawai et al., *J Med Chem* 2019）；LY345899（MTHFD1/2）——PMID 尚待確認。

---

## Part G：Research proposal

### 1. 題目
- 中文：HPV 狀態相關之單碳代謝、O-GlcNAc 調控與免疫逃逸程式於口腔及口咽鱗狀細胞癌之整合性多組學研究
- English: HPV status-associated metabolic, O-GlcNAc and immune-escape programs in oral and oropharyngeal squamous cell carcinoma
- （若 02 稽核證實 oral cavity HPV⁺ Level A/B 樣本足夠，再改為以 OSCC 為主題）

### 2. 研究背景
HPV 陽性頭頸癌以口咽為主，具有 E6/E7 驅動的 p53/RB 失活、E2F 程式活化及較強免疫浸潤；HPV 在口腔（oral cavity）原發腫瘤的角色較不明確，
且常因只用 p16 判定而高估。代謝重編程（單碳代謝、hexosamine biosynthetic pathway）與蛋白 O-GlcNAc 修飾可能連結增生訊號與免疫調節分子；
PD-L1 除細胞表面外亦可經 extracellular vesicles 釋出而影響免疫細胞。

### 3. Knowledge gap
1. 缺乏以 **HPV 轉錄活性（Level A/B）** 區分 HPV-active／inactive／negative 的口腔癌轉錄體比較；
2. MTHFD2、OGT/OGA 與 PD-L1 在 HPV 相關腫瘤中的關係僅有零散線索，缺乏跨資料集驗證與細胞來源解析；
3. CORO1A 在腫瘤細胞 vs 免疫細胞中的來源，以及其與 EV/PD-L1 的關係未知。

### 4. Central hypothesis【研究假說】
HPV transcriptional activity 與 MTHFD2 所代表的單碳代謝重編程相關，並伴隨 OGT/OGA 平衡與 O-GlcNAc 改變，進而與 PD-L1 表現及免疫逃逸相關；
另一方面，HPV 相關免疫壓力可能透過 CORO1A 與 vesicle trafficking 影響 exosomal PD-L1。上述皆為待驗證之關聯，非已證實因果。

### 5. Specific Aim 1（公開資料：HPV 相關基因表徵的穩定性）
以 GSM 層級稽核建立三層 cohort，各資料集內獨立 DEG，再以 random-effects meta-analysis、RRA 與方向一致性界定可重現的 HPV 表徵；
評估 5 個核心基因與 12 類 pathway score；以 GSE65858 比較 HPV-active／inactive／negative。

### 6. Specific Aim 2（細胞來源與免疫關聯）
以 GSE164690、GSE182227、GSE139324 做 patient-level pseudobulk 與 UMI 來源分析，判定 CORO1A、CD274、MTHFD2、OGT 的主要細胞來源；
以 bulk deconvolution＋purity-adjusted partial correlation 交叉驗證；以 CellChat 描述 PD-L1–PD-1 與 MHC-I 訊號在 HPV⁺/⁻ 間的差異。

### 7. Specific Aim 3（實驗驗證與臨床關聯）
(a) GSE65858、TCGA 存活／淋巴結轉移關聯與 HPV×gene interaction；
(b) SCC1/SCC6 vs SCC47/SCC104 之 qPCR、WB、global O-GlcNAc、flow PD-L1、EV PD-L1；
(c) MTHFD2、OGT 操弄＋rescue，讀值為 O-GlcNAc、PD-L1 與 NK/T 細胞殺傷；(d) CORO1A 操弄與 EV 分泌（僅在 Aim 2 證實腫瘤細胞表現時進行）。

### 8. Expected results（可能情境，皆需以資料確認）
- E2F／G2M／DNA repair 在 HPV⁺ 一致上升（HPV biology 的正對照；若未見，應先檢查 HPV 分組是否正確）；
- MTHFD2 與 one-carbon score 在 HPV-active 上升的程度大於 HPV-inactive；
- CD274 與 IFN-γ score 高度相關，purity 調整後 HPV 效應可能減弱；
- CORO1A 在 single-cell 中主要表現於免疫細胞——若如此，CORO1A→EV 假說需修正。

### 9. Potential problems
- oral cavity HPV⁺（Level A/B）樣本數不足；
- 平台異質性高、HPV 定義不一致（heterogeneity 大）；
- mRNA 無法代表 O-GlcNAc 蛋白修飾；
- bulk 訊號被免疫浸潤混淆；
- single-cell 病人數少、HPV 判定可能僅 p16；
- 細胞株部位來源與 HPV 狀態需驗證。

### 10. Alternative strategies
- 題目改為 oral + oropharyngeal，並把 oral cavity 結果列為 exploratory；
- 以 Hedges' g＋REML 並呈現 I² 與 leave-one-out；
- 以 proteomics（如 CPTAC HNSCC，若有 HPV 註記）或自有 WB/O-GlcNAc 補足蛋白層級；
- 以 inferCNV 確認 malignant；以 LIANA 取代 CellChat；
- 若 CORO1A 非腫瘤來源，改以 RAB27A/TSG101 等 EV biogenesis 基因作為 EV 軸的腫瘤端候選。

### 11. Wet-lab validation plan
| 階段 | 實驗 | 目的 |
|---|---|---|
| 0 | STR、HPV16 E6/E7 qPCR、p16 WB（SCC1、SCC6、SCC47、SCC104） | 確認模型身分與 HPV 活性 |
| 1 | qPCR／WB：MTHFD2、OGT、OGA、CORO1A、PD-L1；RL2 global O-GlcNAc；flow PD-L1（±IFN-γ） | 基線差異 |
| 2 | siMTHFD2 / DS18561882 / LY345899 → O-GlcNAc、PD-L1；formate rescue | 檢驗「MTHFD2 → O-GlcNAc → PD-L1」**是否**成立 |
| 3 | siOGT / OSMI-1；Thiamet-G → PD-L1（總量、表面、EV） | OGT/OGA 對 PD-L1 的影響 |
| 4 | CORO1A knockdown／overexpression → EV（NTA、CD63/CD9/CD81/TSG101）與 exosomal PD-L1 | EV 軸 |
| 5 | NK（NK-92 或 primary NK）與 T 細胞殺傷（LDH／Calcein／CD107a），±anti-PD-L1／anti-PD-1 | 功能 |
| 6 | wound healing、Transwell、tumorsphere、apoptosis、viability | 表型 |
| 7 | 關鍵組合之 xenograft（免疫功能需人源化模型或同源模型） | in vivo |
| 必要 | 每個操弄皆需 rescue（re-expression 或代謝物補充）才可宣稱上下游 | 因果推論 |

### 12. Manuscript figure plan
- Fig. 1：研究設計、dataset audit、HPV evidence level（Fig 1–3）
- Fig. 2：各資料集 DEG 與 meta-analysis（Fig 5、8、9）
- Fig. 3：Pathway 與 HPV-active/inactive 比較（Fig 10–12）
- Fig. 4：免疫微環境與 purity 調整（Fig 13–14）
- Fig. 5：Single-cell 細胞來源（Fig 15–17）
- Fig. 6：臨床關聯（Fig 18–19）
- Fig. 7：細胞實驗與工作模型（Fig 20＋wet-lab）
