# GSM 樣本對照表（sample mapping）

本資料夾內容由 `scripts/02_gsm_sample_audit.R` 從各 GSM 的 characteristics 自動產生，**不是**由 series 標題推斷。

| 檔案 | 說明 |
|---|---|
| `gsm_mapping/<GSE>_characteristics_inventory.csv` | 所有 characteristics key/value 與次數，用於人工檢查欄位意義 |
| `gsm_mapping/<GSE>_samples_auto.csv` | 自動分類：GSM、HPV DNA/RNA/p16 原始值、HPV evidence level、HPV group、anatomic site、sample type、臨床變項、三層納入旗標、排除原因 |
| `gsm_mapping/<GSE>_samples_curated.csv` | **人工確認版**（由您依原始論文 supplementary 修正後另存；下游優先讀取） |
| `sample_exclusion_log.csv` | 每一個被排除 GSM 的原因與步驟 |
| `subset_discrepancy_report.txt` | GSE72536（既往 10/4）與 GSE55544（既往 11/8）完整 series 與 subset 差異 |
| `hpv_field_overrides.csv` | 自動偵測欄位錯誤時，指定某資料集的 role（hpv_dna / hpv_rna / p16 / hpv_author / site …）對應哪個 key |

人工確認重點：
1. `anatomic_site == tongue_ambiguous`：需判斷 oral tongue（oral cavity）或 base of tongue（oropharynx）。
2. `hpv_evidence_level == E`：只有作者分組，需回原文確認檢測方法。
3. p16-only（Level D）樣本只進入獨立的 `p16_surrogate_pos_vs_neg` 比較，不與 DNA/RNA-based 比較合併。
4. 同一病人多個 GSM（重複、PBMC、normal）不可重複計入。

本環境（雲端執行）無法連線 NCBI，因此**尚未產生**實際的 GSM 對照表；請在可連網電腦執行
`Rscript scripts/run_all.R` 產生。
