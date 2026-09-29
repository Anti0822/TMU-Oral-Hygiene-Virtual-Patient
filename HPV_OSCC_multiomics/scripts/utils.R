# ============================================================
# utils.R — 所有 scripts 共用函式
# 內容：設定讀取、路徑、log、sample exclusion log、圖檔輸出（PDF/SVG/600dpi PNG）、
#       HPV evidence level 判定、解剖部位分類、probe 合併、基因別名、sessionInfo
# ============================================================

suppressPackageStartupMessages({
  library(yaml)
  library(data.table)
  library(ggplot2)
})

# ---------- 專案根目錄與設定 ----------
find_project_root <- function(start = getwd()) {
  d <- normalizePath(start, mustWork = FALSE)
  for (i in 1:6) {
    if (file.exists(file.path(d, "config", "config.yaml"))) return(d)
    d <- dirname(d)
  }
  stop("找不到 config/config.yaml；請在專案根目錄 HPV_OSCC_multiomics/ 內執行。")
}
# 確保 UTF-8（config 與 log 含中文）；Windows 請用 R >= 4.2（UTF-8 native）
invisible(tryCatch(if (!l10n_info()$`UTF-8`) Sys.setlocale("LC_CTYPE", "C.UTF-8"), error = function(e) NULL))
PROJ <- find_project_root()
CFG  <- yaml::yaml.load(paste(readLines(file.path(PROJ, "config", "config.yaml"), encoding = "UTF-8", warn = FALSE), collapse = "\n"))

pp <- function(key, ...) {
  if (!key %in% names(CFG$paths)) stop("未知路徑 key: ", key)
  p <- file.path(PROJ, CFG$paths[[key]], ...)
  dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
  p
}

pdir <- function(key, ...) {
  p <- file.path(PROJ, CFG$paths[[key]], ...)
  dir.create(p, recursive = TRUE, showWarnings = FALSE)
  p
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

set_project_seed <- function() set.seed(CFG$seed)

# ---------- 套件檢查 ----------
require_pkgs <- function(pkgs, optional = FALSE) {
  ok <- vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)
  if (!all(ok)) {
    msg <- paste0("缺少套件: ", paste(pkgs[!ok], collapse = ", "),
                  "；請先執行 scripts/00_setup_packages.R")
    if (optional) { message("[optional] ", msg); return(invisible(ok)) }
    stop(msg)
  }
  invisible(ok)
}

# ---------- Log ----------
.log_file <- NULL
start_log <- function(script_name) {
  .log_file <<- pp("results", "logs", paste0(script_name, "_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".log"))
  log_msg("=== START ", script_name, " | seed = ", CFG$seed, " ===")
}
log_msg <- function(...) {
  line <- paste0("[", format(Sys.time(), "%H:%M:%S"), "] ", paste0(...))
  message(line)
  if (!is.null(.log_file)) cat(line, "\n", file = .log_file, append = TRUE)
}

# sample exclusion log：每個被排除的 GSM 都要記錄原因
log_exclusion <- function(dataset, gsm, reason, step) {
  f <- pp("metadata", "sample_exclusion_log.csv")
  row <- data.table(timestamp = format(Sys.time()), dataset = dataset,
                    gsm = gsm, step = step, reason = reason)
  fwrite(row, f, append = file.exists(f))
  invisible(row)
}

finish_script <- function(script_name) {
  f <- pp("results", "sessionInfo", paste0(script_name, "_sessionInfo.txt"))
  writeLines(capture.output(sessionInfo()), f)
  log_msg("=== END ", script_name, " | sessionInfo -> ", f, " ===")
}

# ---------- 圖檔輸出：PDF + SVG + 600 dpi PNG ----------
save_fig <- function(plot, name, width = 7, height = 5, subdir = NULL) {
  base <- if (is.null(subdir)) pp("figures", name) else pp("figures", subdir, name)
  draw <- function() {
    if (inherits(plot, c("ggplot", "patchwork"))) print(plot)
    else if (inherits(plot, "Heatmap") || inherits(plot, "HeatmapList")) ComplexHeatmap::draw(plot)
    else if (is.function(plot)) plot()
    else print(plot)
  }
  # cairo_pdf 可嵌入系統字型（含中文）；不可用時退回 pdf()
  if (capabilities("cairo")) grDevices::cairo_pdf(paste0(base, ".pdf"), width = width, height = height)
  else grDevices::pdf(paste0(base, ".pdf"), width = width, height = height, useDingbats = FALSE)
  draw(); grDevices::dev.off()
  if (requireNamespace("svglite", quietly = TRUE)) {
    svglite::svglite(paste0(base, ".svg"), width = width, height = height); draw(); grDevices::dev.off()
  } else {
    grDevices::svg(paste0(base, ".svg"), width = width, height = height); draw(); grDevices::dev.off()
  }
  if (requireNamespace("ragg", quietly = TRUE)) {
    ragg::agg_png(paste0(base, ".png"), width = width, height = height, units = "in", res = 600)
  } else {
    grDevices::png(paste0(base, ".png"), width = width, height = height, units = "in", res = 600)
  }
  draw(); grDevices::dev.off()
  log_msg("Figure saved: ", base, ".{pdf,svg,png}")
  invisible(base)
}

theme_pub <- function(base_size = 10) {
  theme_bw(base_size = base_size) +
    theme(panel.grid.minor = element_blank(), strip.background = element_rect(fill = "grey92"),
          legend.key.size = unit(0.4, "cm"))
}
HPV_COLORS <- c(HPV_pos = "#C0392B", HPV_neg = "#2E86C1", HPV_active = "#C0392B",
                HPV_inactive = "#F39C12", Unknown = "grey60")

# ---------- 基因別名：MGEA5 → OGA ----------
# 所有矩陣統一轉成 HGNC 現行符號（OGA）；報表同時顯示 "OGA (MGEA5)"
harmonize_symbols <- function(sym) {
  sym <- toupper(trimws(sym))
  for (official in names(CFG$gene_aliases)) {
    sym[sym %in% toupper(CFG$gene_aliases[[official]])] <- official
  }
  sym
}
display_symbol <- function(sym) ifelse(sym == "OGA", "OGA (MGEA5)", sym)

# ---------- HPV evidence level ----------
# 依使用者規格：
#  A：HPV DNA+ 且 E6/E7 RNA+，或有 transcriptionally active HPV 證據
#  B：HPV RNA+（無 DNA 資訊）
#  C：HPV DNA+，無 RNA 活性證據
#  D：僅 p16+
#  E：定義不明／僅作者分組
# p16 絕不單獨升級為 active。
classify_hpv_evidence <- function(dna = NA, rna = NA, p16 = NA, author_label = NA) {
  pos <- function(x) !is.na(x) & grepl("^(pos|positive|\\+|1|yes|true|active)", tolower(x))
  neg <- function(x) !is.na(x) & grepl("^(neg|negative|-|0|no|false)", tolower(x))
  n <- max(length(dna), length(rna), length(p16), length(author_label))
  dna <- rep_len(dna, n); rna <- rep_len(rna, n); p16 <- rep_len(p16, n); author_label <- rep_len(author_label, n)
  level <- rep("E", n); group <- rep("Unknown", n)

  a <- pos(dna) & pos(rna);                 level[a] <- "A"; group[a] <- "HPV_active"
  b <- !a & pos(rna);                       level[b] <- "B"; group[b] <- "HPV_active"
  # DNA+ 但 RNA 明確陰性 → Level C（無 RNA 活性證據），分組為 HPV_inactive
  c <- !a & !b & pos(dna) & neg(rna);       level[c] <- "C"; group[c] <- "HPV_inactive"
  # DNA+ 但 RNA 未檢測 → Level C，不可歸為 active 或 inactive
  c2 <- !a & !b & !c & pos(dna);            level[c2] <- "C"; group[c2] <- "HPV_pos_DNA_only"
  # HPV 陰性：依陰性判定所用檢測的強度給 level（DNA- 且 RNA- → A；僅 RNA- → B；僅 DNA- → C）
  nn <- (neg(dna) | neg(rna)) & !pos(dna) & !pos(rna)
  level[nn] <- ifelse(neg(dna[nn]) & neg(rna[nn]), "A", ifelse(neg(rna[nn]), "B", "C"))
  group[nn] <- "HPV_neg"
  d <- level == "E" & pos(p16);             level[d] <- "D"; group[d] <- "p16_pos_only"
  d2 <- level == "E" & neg(p16);            level[d2] <- "D"; group[d2] <- "p16_neg_only"
  e <- level == "E" & pos(author_label);    group[e] <- "HPV_pos_author"
  e2 <- level == "E" & neg(author_label);   group[e2] <- "HPV_neg_author"
  data.table(hpv_evidence_level = level, hpv_group_detail = group,
             hpv_binary = fcase(group %in% c("HPV_active", "HPV_inactive", "HPV_pos_DNA_only",
                                             "HPV_pos_author"), "HPV_pos",
                                group %in% c("HPV_neg", "HPV_neg_author"), "HPV_neg",
                                default = NA_character_),
             # p16 surrogate 分組：只用於獨立的 "p16_surrogate" 比較，不與 DNA/RNA-based 比較混合
             hpv_p16_surrogate = fcase(group == "p16_pos_only", "HPV_pos", group == "p16_neg_only", "HPV_neg",
                                       default = NA_character_))
}

# ---------- 解剖部位分類 ----------
# 嚴格區分 oral cavity 與 oropharynx。注意：「tongue」需區分 oral tongue（前 2/3）
# 與 base of tongue（oropharynx）；僅寫 "tongue" 者標記 ambiguous，需人工核對。
classify_site <- function(x) {
  s <- tolower(ifelse(is.na(x), "", x))
  out <- rep("unknown", length(s))
  out[grepl("oral cavity|oral tongue|mobile tongue|anterior tongue|floor of (the )?mouth|fom\\b|buccal|gingiva|gum|alveol|hard palate|retromolar|lip|oral\\b|mouth", s)] <- "oral_cavity"
  out[grepl("oropharyn|tonsil|base of (the )?tongue|tongue base|\\bbot\\b|soft palate|uvula|vallecula|pharyngeal wall", s)] <- "oropharynx"
  out[grepl("laryn|glott|epiglott", s)] <- "larynx"
  out[grepl("hypopharyn|pyriform|piriform", s)] <- "hypopharynx"
  out[grepl("nasophar|sinonasal|nasal", s)] <- "other_HN"
  out[out == "unknown" & grepl("\\btongue\\b", s)] <- "tongue_ambiguous"
  out[grepl("cervix|cervical cancer|uter", s)] <- "cervix"
  out
}

# ---------- 多 probe → 單一 gene symbol ----------
# 規則（預設 "max_mean"）：同一 symbol 多個 probe 時，保留跨樣本平均表現最高者
# （代表最可靠偵測的 probe）；可選 "median" 取 probe 中位數。
# 對應多個 symbol 的 probe（"A /// B"）先排除，避免重複計算。
collapse_probes <- function(expr, symbols, method = c("max_mean", "median")) {
  method <- match.arg(method)
  stopifnot(nrow(expr) == length(symbols))
  keep <- !is.na(symbols) & symbols != "" & !grepl("///|//", symbols)
  expr <- expr[keep, , drop = FALSE]; symbols <- harmonize_symbols(symbols[keep])
  if (method == "max_mean") {
    mm <- rowMeans(expr, na.rm = TRUE)
    o <- order(symbols, -mm)
    first <- !duplicated(symbols[o])
    out <- expr[o[first], , drop = FALSE]
    rownames(out) <- symbols[o[first]]
  } else {
    out <- do.call(rbind, lapply(split(seq_along(symbols), symbols), function(i)
      apply(expr[i, , drop = FALSE], 2, median, na.rm = TRUE)))
  }
  out
}

# ---------- 其他 ----------
safe_fwrite <- function(x, file, ...) {
  dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE)
  data.table::fwrite(x, file, ...)
  log_msg("Table saved: ", file)
}

assert_that <- function(cond, msg) if (!isTRUE(cond)) stop("[檢查失敗] ", msg, call. = FALSE)

# 讀取稽核後的樣本表（由 02_gsm_sample_audit.R 產生、並經人工確認的 curated 版本優先）
read_sample_map <- function(gse) {
  cur <- pp("metadata", "gsm_mapping", paste0(gse, "_samples_curated.csv"))
  auto <- pp("metadata", "gsm_mapping", paste0(gse, "_samples_auto.csv"))
  f <- if (file.exists(cur)) cur else auto
  if (!file.exists(f)) stop("尚未完成 ", gse, " 的 GSM 稽核，請先執行 02_gsm_sample_audit.R")
  if (f == auto) log_msg("[警告] ", gse, " 使用自動分類結果，尚未人工確認（*_samples_curated.csv 不存在）")
  fread(f)
}
