# ============================================================
# 02_gsm_sample_audit.R — 逐一 GSM 稽核：HPV evidence level、解剖部位、樣本型態、臨床變項
#
# 原則：
#  * 分組只依據每個 GSM 的 characteristics / source / description，不依 series 標題推斷。
#  * p16 單獨陽性只給 Level D，不會被歸為 HPV-active。
#  * "tongue" 未註明 oral/base 者標為 tongue_ambiguous，需人工核對原始論文。
#  * 自動結果寫入 *_samples_auto.csv；人工確認後另存 *_samples_curated.csv（下游優先讀 curated）。
#  * 欄位對應可用 00_metadata/hpv_field_overrides.csv 覆寫（自動偵測錯誤時使用）。
#
# 輸出：
#   00_metadata/gsm_mapping/<GSE>_characteristics_inventory.csv  所有 key/value 及次數
#   00_metadata/gsm_mapping/<GSE>_samples_auto.csv              每個 GSM 的分類結果
#   10_tables/Table_S2_sample_counts_by_dataset.csv            HPV × site × sample type 交叉表
#   10_tables/Table_S3_core_gene_detectability.csv             核心基因是否可測
#   00_metadata/subset_discrepancy_report.txt                  與既往分析 subset 的差異說明
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
source(file.path(.src(), "utils.R"))
require_pkgs(c("Biobase"))
suppressPackageStartupMessages(library(Biobase))
set_project_seed(); start_log("02_gsm_sample_audit")

args <- commandArgs(trailingOnly = TRUE)
raw_root <- pdir("raw")
ids <- if (length(args)) args else list.dirs(raw_root, recursive = FALSE, full.names = FALSE)
ids <- ids[grepl("^GSE", ids)]
map_dir <- pdir("metadata", "gsm_mapping")

# ---------- 值正規化 ----------
norm_posneg <- function(v) {
  x <- tolower(trimws(as.character(v)))
  out <- rep(NA_character_, length(x))
  out[grepl("neg|absent|^no$|^-$|not detected|undetect|^0$|hpv-$|hpv \\(-\\)|^n$", x)] <- "neg"
  out[is.na(out) & grepl("pos|present|^yes$|^\\+$|detected|^1$|hpv\\+|hpv16|hpv-16|hpv 16|hpv18|\\(\\+\\)|^p$", x)] <- "pos"
  out[x %in% c("", "na", "n/a", "unknown", "nd", "not available", "not tested")] <- NA
  out
}

# ---------- 欄位偵測 ----------
detect_fields <- function(keys) {
  k <- tolower(keys)
  list(
    hpv_rna    = keys[grepl("hpv|papilloma|e6|e7", k) & grepl("rna|e6|e7|transcri|activ|express", k)],
    hpv_dna    = keys[grepl("hpv|papilloma", k) & grepl("dna|pcr|ish|genotyp|type|load", k) & !grepl("rna|e6|e7|activ", k)],
    p16        = keys[grepl("p16|cdkn2a", k)],
    hpv_author = keys[grepl("hpv|papilloma", k) & !grepl("rna|e6|e7|dna|pcr|ish|p16|genotyp|load|activ|express", k)],
    site       = keys[grepl("site|location|subsite|anatom|organ|primary tumou?r|tissue|localization|tumou?r loc", k)],
    cell_type  = keys[grepl("cell type|cell line|celltype|disease state|sample type|tissue type|specimen", k)],
    age        = keys[grepl("^age|age at|age \\(", k)],
    sex        = keys[grepl("^sex|gender", k)],
    stage      = keys[grepl("stage|uicc|ajcc", k) & !grepl("\\bt\\b|\\bn\\b|\\bm\\b", k)],
    t_stage    = keys[grepl("^t[ _-]?stage|^t$|tumou?r size|pt|t category|t classification", k)],
    n_stage    = keys[grepl("^n[ _-]?stage|^n$|node|nodal|pn|n category|n classification|lymph", k)],
    smoking    = keys[grepl("smok|tobacco|pack", k)],
    alcohol    = keys[grepl("alcohol|drink", k)],
    os_time    = keys[grepl("(os|overall surv|survival|follow).*(time|month|day|year)|time.*(os|surv|death)", k)],
    os_event   = keys[grepl("vital|death|dead|os.?event|os.?status|survival status|censor", k)],
    pfs_time   = keys[grepl("(pfs|dfs|rfs|recur|progress|relapse).*(time|month|day|year)", k)],
    pfs_event  = keys[grepl("(pfs|dfs|rfs|recur|progress|relapse)", k) & !grepl("time|month|day|year", k)],
    treatment  = keys[grepl("treat|therap|radiat|chemo|surgery|cetux|immuno", k)],
    tumor_kind = keys[grepl("primary|metasta|recurr", k)]
  )
}

# 讀取人工覆寫：dataset, role, key （role 同上 names）
overrides_f <- pp("metadata", "hpv_field_overrides.csv")
overrides <- if (file.exists(overrides_f)) fread(overrides_f) else data.table(dataset = character(), role = character(), key = character())

first_nonNA <- function(dt, cols) {
  if (!length(cols)) return(rep(NA_character_, nrow(dt)))
  m <- as.matrix(dt[, ..cols]); m[m == ""] <- NA
  apply(m, 1, function(r) { r <- r[!is.na(r)]; if (length(r)) paste(unique(r), collapse = " | ") else NA_character_ })
}

audit_one <- function(gse) {
  f <- file.path(raw_root, gse, paste0(gse, "_pheno_raw.csv"))
  if (!file.exists(f)) { log_msg("[略過] ", gse, "：找不到 pheno_raw（請先執行 01）"); return(NULL) }
  pd <- fread(f, colClasses = "character")
  gsm_col <- if ("geo_accession" %in% names(pd)) "geo_accession" else "gsm_rowname"
  ch_cols <- grep(":ch1$|:ch2$", names(pd), value = TRUE)
  # 若 GEOquery 未拆成 key:ch1，改由 characteristics_ch1.* 自行拆解 "key: value"
  if (!length(ch_cols)) {
    raw_ch <- grep("^characteristics_ch", names(pd), value = TRUE)
    for (cc in raw_ch) {
      kv <- tstrsplit(pd[[cc]], ":\\s*", keep = 1:2)
      keys <- unique(na.omit(kv[[1]]))
      for (kk in keys) {
        nm <- paste0(kk, ":ch1"); if (!nm %in% names(pd)) pd[, (nm) := NA_character_]
        idx <- which(kv[[1]] == kk); set(pd, idx, nm, kv[[2]][idx])
      }
    }
    ch_cols <- grep(":ch1$", names(pd), value = TRUE)
  }
  keys <- sub(":ch[12]$", "", ch_cols)
  # ---- inventory ----
  inv <- rbindlist(lapply(ch_cols, function(cc) {
    tb <- pd[, .N, by = c(cc)]; setnames(tb, 1, "value"); tb[, key := sub(":ch[12]$", "", cc)]; tb
  }))
  extra <- rbindlist(lapply(intersect(c("source_name_ch1", "title", "description", "organism_ch1", "platform_id"), names(pd)),
                            function(cc) { tb <- pd[, .N, by = c(cc)]; setnames(tb, 1, "value"); tb[, key := cc]; tb }))
  inv <- rbind(inv, extra, fill = TRUE)[order(key, -N)]
  fwrite(inv[, .(key, value, N)], file.path(map_dir, paste0(gse, "_characteristics_inventory.csv")))

  fields <- detect_fields(keys)
  ov <- overrides[dataset == gse]
  for (r in unique(ov$role)) fields[[r]] <- ov[role == r, key]
  colmap <- function(role) paste0(fields[[role]], ":ch1")[paste0(fields[[role]], ":ch1") %in% names(pd)]
  getv <- function(role) first_nonNA(pd, colmap(role))

  src   <- first_nonNA(pd, intersect(c("source_name_ch1"), names(pd)))
  ttl   <- pd[["title"]] %||% rep(NA, nrow(pd))
  desc  <- first_nonNA(pd, grep("^description", names(pd), value = TRUE))

  hpv_rna_raw <- getv("hpv_rna"); hpv_dna_raw <- getv("hpv_dna")
  p16_raw <- getv("p16"); hpv_author_raw <- getv("hpv_author")
  # 若作者欄位本身即為 active/inactive/negative 三分類（例：HPV-active 分組），轉成 DNA/RNA 證據
  act <- tolower(hpv_author_raw)
  rna_from_author <- fifelse(grepl("inactive", act), "neg", fifelse(grepl("active", act), "pos", NA_character_))
  dna_from_author <- fifelse(grepl("active", act), "pos", NA_character_)
  # 組合值（例如 "DNA+RNA-"、"HPV16 DNA pos / RNA neg"）：從任何 HPV 欄位分別抽出 DNA 與 RNA 狀態
  all_hpv_txt <- tolower(paste(hpv_rna_raw, hpv_dna_raw, hpv_author_raw))
  pick <- function(tag) {
    pat <- paste0(tag, "\\s*[:=]?\\s*(\\+|-|pos|neg)")
    pos <- regexpr(pat, all_hpv_txt); hit <- !is.na(pos) & pos > 0
    out <- rep(NA_character_, length(all_hpv_txt))
    m <- regmatches(all_hpv_txt[hit], regexpr(pat, all_hpv_txt[hit]))
    out[hit] <- ifelse(grepl("(\\+|pos)$", m), "pos", "neg")
    out
  }
  rna_combo <- pick("rna"); dna_combo <- pick("dna")
  rna_norm <- fcoalesce(rna_combo, norm_posneg(hpv_rna_raw), rna_from_author)
  dna_norm <- fcoalesce(dna_combo, norm_posneg(hpv_dna_raw), dna_from_author)
  hpv <- classify_hpv_evidence(dna = dna_norm, rna = rna_norm, p16 = norm_posneg(p16_raw),
                               author_label = norm_posneg(hpv_author_raw))

  site_raw <- getv("site")
  site_text <- paste(site_raw, src, ttl, desc)
  site_cls <- classify_site(fifelse(is.na(site_raw), paste(src, ttl), site_raw))
  # 若 site 欄無法判斷，再用 source/title/description 補判；補判結果另標註來源
  site_source <- fifelse(site_cls != "unknown", "characteristics", "source/title/description")
  site_cls2 <- fifelse(site_cls == "unknown", classify_site(site_text), site_cls)

  st_text <- tolower(paste(getv("cell_type"), src, ttl, desc))
  sample_type <- fcase(
    grepl("cell line|cell-line|\\bscc-?\\d|um-scc|upci|93vu|hacat|cultured|keratinocyte line", st_text), "cell_line",
    grepl("pbmc|peripheral blood|\\bblood\\b|plasma|serum", st_text), "blood",
    grepl("normal|non-?tumou?r|adjacent|healthy|uppp|control", st_text) & !grepl("tumou?r tissue", st_text), "normal",
    grepl("lymph node|metasta", st_text), "metastasis",
    grepl("tumou?r|carcinoma|cancer|scc|hnscc|til|cd45", st_text), "tumor",
    default = "unknown")
  tk <- tolower(paste(getv("tumor_kind"), st_text))
  tumor_status <- fcase(grepl("recurr", tk), "recurrent", grepl("metasta|lymph node", tk), "metastatic",
                        sample_type == "tumor", "primary_or_unspecified", default = NA_character_)

  out <- data.table(
    dataset = gse, gsm = pd[[gsm_col]], title = ttl, source_name = src,
    platform = pd[["platform_id"]] %||% NA, sample_type = sample_type, tumor_status = tumor_status,
    site_raw = site_raw, anatomic_site = site_cls2, site_call_source = site_source,
    hpv_dna_raw = hpv_dna_raw, hpv_rna_raw = hpv_rna_raw, p16_raw = p16_raw, hpv_author_raw = hpv_author_raw,
    hpv, age = getv("age"), sex = getv("sex"), stage = getv("stage"), t_stage = getv("t_stage"),
    n_stage = getv("n_stage"), smoking = getv("smoking"), alcohol = getv("alcohol"),
    os_time = getv("os_time"), os_event = getv("os_event"), pfs_time = getv("pfs_time"),
    pfs_event = getv("pfs_event"), treatment = getv("treatment"))

  # ---- 三層分析的納入規則 ----
  out[, is_tumor := sample_type %in% c("tumor") ]
  out[, has_hpv := !is.na(hpv_binary) | !is.na(hpv_p16_surrogate)]
  out[, include_primary_OSCC := is_tumor & anatomic_site == "oral_cavity" & has_hpv]
  out[, include_secondary_OPSCC := is_tumor & anatomic_site == "oropharynx" & has_hpv]
  out[, include_sensitivity_HNSCC := is_tumor & anatomic_site %in% c("oral_cavity", "oropharynx", "larynx",
                                     "hypopharynx", "tongue_ambiguous", "unknown", "other_HN") & has_hpv]
  out[, exclusion_reason := fcase(
    sample_type == "cell_line", "cell line（不納入臨床 DEG，另作功能驗證）",
    sample_type == "blood", "blood/PBMC",
    sample_type == "normal", "normal tissue（不納入 HPV⁺ vs HPV⁻ tumor 比較）",
    anatomic_site == "cervix", "非頭頸部（cervix）",
    !has_hpv, paste0("HPV 狀態無法判定（group = ", hpv_group_detail, "）"),
    anatomic_site == "tongue_ambiguous", "tongue 未區分 oral/base：僅進 sensitivity，需人工核對",
    anatomic_site == "unknown", "部位不明：僅進 sensitivity",
    default = NA_character_)]
  for (i in which(!out$include_sensitivity_HNSCC)) log_exclusion(gse, out$gsm[i], out$exclusion_reason[i], "02_gsm_audit")

  fwrite(out, file.path(map_dir, paste0(gse, "_samples_auto.csv")))
  log_msg(gse, "：", nrow(out), " GSM；偵測欄位 = ",
          paste(names(fields)[lengths(fields) > 0], collapse = ","))
  if (!length(c(fields$hpv_rna, fields$hpv_dna, fields$hpv_author, fields$p16)))
    log_msg("[警告] ", gse, " 在 characteristics 中找不到任何 HPV 欄位 → 需從原始論文 supplementary 取得，暫列 Level E")
  out
}

all_samples <- rbindlist(lapply(ids, audit_one), fill = TRUE)
assert_that(nrow(all_samples) > 0, "沒有任何資料集完成稽核")
safe_fwrite(all_samples, pp("metadata", "gsm_mapping", "ALL_samples_auto.csv"))

# ---------- 交叉表 ----------
counts <- all_samples[, .(
  n_total = .N,
  n_tumor = sum(sample_type == "tumor"),
  n_p16_surrogate_pos = sum(hpv_p16_surrogate == "HPV_pos", na.rm = TRUE), n_p16_surrogate_neg = sum(hpv_p16_surrogate == "HPV_neg", na.rm = TRUE),
  n_normal = sum(sample_type == "normal"),
  n_cell_line = sum(sample_type == "cell_line"),
  n_blood = sum(sample_type == "blood"),
  n_HPV_pos = sum(hpv_binary == "HPV_pos", na.rm = TRUE),
  n_HPV_neg = sum(hpv_binary == "HPV_neg", na.rm = TRUE),
  n_HPV_active = sum(hpv_group_detail == "HPV_active"),
  n_HPV_inactive = sum(hpv_group_detail == "HPV_inactive"),
  n_p16_only = sum(hpv_group_detail %in% c("p16_pos_only", "p16_neg_only")),
  n_oral_cavity = sum(anatomic_site == "oral_cavity"),
  n_oropharynx = sum(anatomic_site == "oropharynx"),
  n_larynx = sum(anatomic_site == "larynx"), n_hypopharynx = sum(anatomic_site == "hypopharynx"),
  n_tongue_ambiguous = sum(anatomic_site == "tongue_ambiguous"),
  n_site_unknown = sum(anatomic_site == "unknown"),
  n_primary_OSCC_HPVpos = sum(include_primary_OSCC & hpv_binary == "HPV_pos", na.rm = TRUE),
  n_primary_OSCC_HPVneg = sum(include_primary_OSCC & hpv_binary == "HPV_neg", na.rm = TRUE),
  n_OPSCC_HPVpos = sum(include_secondary_OPSCC & hpv_binary == "HPV_pos", na.rm = TRUE),
  n_OPSCC_HPVneg = sum(include_secondary_OPSCC & hpv_binary == "HPV_neg", na.rm = TRUE),
  hpv_levels = paste(names(table(hpv_evidence_level)), table(hpv_evidence_level), sep = ":", collapse = ";"),
  has_survival = any(!is.na(os_time)), has_smoking = any(!is.na(smoking)), has_alcohol = any(!is.na(alcohol))
), by = dataset]
safe_fwrite(counts, pp("tables", "Table_S2_sample_counts_by_dataset.csv"))

detail <- all_samples[, .N, by = .(dataset, sample_type, anatomic_site, hpv_evidence_level, hpv_group_detail)][order(dataset)]
safe_fwrite(detail, pp("tables", "Table_S2b_sample_crosstab_detail.csv"))

# ---------- 核心基因可測性 ----------
gene_check <- rbindlist(lapply(ids, function(gse) {
  f <- file.path(raw_root, gse, paste0(gse, "_eset_list.rds"))
  if (!file.exists(f)) return(NULL)
  esets <- readRDS(f)
  rbindlist(lapply(names(esets), function(nm) {
    e <- esets[[nm]]; fd <- fData(e)
    symcol <- grep("^(gene.?symbol|symbol|gene_symbol|ilmn_gene|gene_assignment|gene name)$",
                   names(fd), ignore.case = TRUE, value = TRUE)[1]
    syms <- if (!is.na(symcol)) {
      s <- as.character(fd[[symcol]])
      if (grepl("assignment", symcol, ignore.case = TRUE)) s <- sapply(strsplit(s, " // "), `[`, 2)
      harmonize_symbols(unlist(strsplit(s, " /// ")))
    } else character()
    data.table(dataset = gse, series_matrix = nm, n_features = nrow(e), symbol_column = symcol %||% NA,
               OGT = "OGT" %in% syms, OGA_MGEA5 = "OGA" %in% syms, MTHFD2 = "MTHFD2" %in% syms,
               CORO1A = "CORO1A" %in% syms, CD274 = "CD274" %in% syms,
               note = if (nrow(e) == 0) "series matrix 無表現值（RNA-seq/scRNA）：需由 supplementary counts 檢查" else "")
  }))
}), fill = TRUE)
if (nrow(gene_check)) safe_fwrite(gene_check, pp("tables", "Table_S3_core_gene_detectability.csv"))

# ---------- 與既往分析 subset 的差異 ----------
prior <- data.table(dataset = c("GSE72536", "GSE55544"), prior_HPVpos = c(10, 11), prior_HPVneg = c(4, 8))
rep_lines <- c("既往分析 subset 與完整 series 的比對（自動產生，請人工確認）", "")
for (i in seq_len(nrow(prior))) {
  d <- prior$dataset[i]; s <- all_samples[dataset == d]
  if (!nrow(s)) { rep_lines <- c(rep_lines, paste0(d, "：尚未下載，無法比對")); next }
  rep_lines <- c(rep_lines, paste0("== ", d, " ==  完整 series GSM 數 = ", nrow(s),
                                   "；既往 subset = ", prior$prior_HPVpos[i], " HPV⁺ / ", prior$prior_HPVneg[i], " HPV⁻"),
                 capture.output(print(s[, .N, by = .(sample_type, anatomic_site, hpv_group_detail)][order(-N)])),
                 paste0("  若只取 oral_cavity tumor：HPV⁺ = ", s[include_primary_OSCC & hpv_binary == "HPV_pos", .N],
                        "，HPV⁻ = ", s[include_primary_OSCC & hpv_binary == "HPV_neg", .N]),
                 paste0("  若只取 oropharynx tumor：HPV⁺ = ", s[include_secondary_OPSCC & hpv_binary == "HPV_pos", .N],
                        "，HPV⁻ = ", s[include_secondary_OPSCC & hpv_binary == "HPV_neg", .N]),
                 "  → 判讀：比較上述何種篩選組合可重現既往數字；若皆無法重現，須回查原分析的樣本清單。", "")
}
writeLines(rep_lines, pp("metadata", "subset_discrepancy_report.txt"))
finish_script("02_gsm_sample_audit")
