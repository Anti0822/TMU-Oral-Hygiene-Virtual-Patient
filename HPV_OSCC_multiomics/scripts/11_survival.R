# ============================================================
# 11_survival.R — 臨床與存活分析（GSE65858、TCGA-HNSC）
#
#  分層：site（oral_cavity / oropharynx / all）× HPV（all / HPV_pos / HPV_neg）
#  分析：
#   * Kaplan–Meier（預先指定 median split；不使用 optimal cutpoint 以免過度擬合）+ log-rank
#   * Univariate Cox（連續，每 1 SD）
#   * Multivariable Cox：age、sex、stage、site、smoking、HPV、treatment、purity（有資料者才納入；EPV 檢查）
#   * HPV × gene interaction（likelihood-ratio test）
#   * Restricted cubic spline（events ≥ 50 時，rms::cph，3 knots）
#   * Composite：MTHFD2-high/OGT-high/CD274-high；CORO1A-high/CD274-high
#   * Pathway scores（07 輸出）與存活
#   * 淋巴結轉移（N+ vs N0）logistic regression
#  結果只描述 association，不作因果結論。PH 假設以 cox.zph 檢查並輸出。
#
#  TCGA HPV 狀態：優先使用 00_metadata/tcga_hnsc_hpv_rna_status.csv（欄位 sample, hpv_rna = pos/neg；
#  來源建議：TCGA Network, Nature 2015 之 RNA-seq E6/E7 reads 判定）→ Level A/B；
#  若無此檔，退而使用 clinicalMatrix 的 ISH（Level C）/ p16（Level D），並在結果中標註。
# ============================================================
.src <- function() { f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirname(normalizePath(sub("^--file=", "", f[1]))) else file.path(getwd(), "scripts") }
source(file.path(.src(), "utils.R"))
require_pkgs(c("survival")); suppressPackageStartupMessages(library(survival))
has <- function(p) requireNamespace(p, quietly = TRUE)
set_project_seed(); start_log("11_survival")
CORE <- harmonize_symbols(CFG$core_genes)
args <- commandArgs(trailingOnly = TRUE)

# ---------- cohort loaders ----------
col_or_na <- function(dt, ...) { for (n in c(...)) if (n %in% names(dt)) return(dt[[n]]); rep(NA_character_, nrow(dt)) }
to_num <- function(x) suppressWarnings(as.numeric(gsub("[^0-9.eE-]", "", x)))
to_event <- function(x) { x <- tolower(x); fcase(grepl("dead|deceased|died|^1$|yes|event|progress|recur|relapse", x), 1L,
                                                  grepl("alive|living|^0$|no|censor", x), 0L, default = NA_integer_) }

load_geo_cohort <- function(gse) {
  f <- pp("processed", paste0(gse, "_gene_expr.rds")); if (!file.exists(f)) return(NULL)
  obj <- readRDS(f); s <- copy(obj$samples)[sample_type == "tumor"]
  s[, `:=`(os_t = to_num(os_time), os_e = to_event(os_event), pfs_t = to_num(pfs_time), pfs_e = to_event(pfs_event),
           age_n = to_num(age))]
  sc <- pp("pathway", paste0(gse, "_scores.rds"))
  scores <- if (file.exists(sc)) readRDS(sc)$gsva else NULL
  list(name = gse, expr = obj$expr[, s$gsm], samples = s, scores = scores)
}

load_tcga <- function() {
  if (!has("UCSCXenaTools")) { log_msg("[略過 TCGA] 未安裝 UCSCXenaTools"); return(NULL) }
  cache <- pdir("raw", "TCGA_HNSC")
  get_x <- function(host, ds) {
    q <- UCSCXenaTools::XenaGenerate(subset = XenaHostNames == host) |> UCSCXenaTools::XenaFilter(filterDatasets = ds)
    UCSCXenaTools::XenaQuery(q) |> UCSCXenaTools::XenaDownload(destdir = cache, trans_slash = TRUE) |> UCSCXenaTools::XenaPrepare()
  }
  ex <- tryCatch(get_x("tcgaHub", "TCGA.HNSC.sampleMap/HiSeqV2$"), error = function(e) NULL)
  cl <- tryCatch(get_x("tcgaHub", "TCGA.HNSC.sampleMap/HNSC_clinicalMatrix"), error = function(e) NULL)
  sv <- tryCatch(get_x("pancanAtlasHub", "Survival_SupplementalTable_S1_20171025_xena_sp"), error = function(e) NULL)
  if (is.null(ex) || is.null(cl)) { log_msg("[略過 TCGA] Xena 下載失敗"); return(NULL) }
  ex <- as.data.frame(ex); rownames(ex) <- harmonize_symbols(ex[[1]]); ex <- as.matrix(ex[!duplicated(rownames(ex)), -1])
  cl <- as.data.table(cl); setnames(cl, 1, "sample")
  s <- data.table(sample = colnames(ex))[, gsm := sample]
  s <- merge(s, cl, by = "sample", all.x = TRUE)
  s <- s[substr(sample, 14, 15) == "01"]                       # primary tumor only
  if (!is.null(sv)) { sv <- as.data.table(sv); s <- merge(s, sv[, .(sample, OS, OS.time, PFI, PFI.time)], by = "sample", all.x = TRUE) }
  s[, anatomic_neoplasm_subdivision := col_or_na(s, "anatomic_neoplasm_subdivision")]
  s[, anatomic_site := classify_site(anatomic_neoplasm_subdivision)]
  s[anatomic_neoplasm_subdivision %in% c("Oral Tongue", "Floor of mouth", "Buccal Mucosa", "Alveolar Ridge", "Hard Palate", "Lip", "Oral Cavity"), anatomic_site := "oral_cavity"]
  s[anatomic_neoplasm_subdivision %in% c("Base of tongue", "Tonsil", "Oropharynx"), anatomic_site := "oropharynx"]
  hf <- pp("metadata", "tcga_hnsc_hpv_rna_status.csv")
  if (file.exists(hf)) {
    h <- fread(hf); s[, pid := substr(sample, 1, 12)]; h[, pid := substr(sample, 1, 12)]
    s <- merge(s, h[, .(pid, hpv_rna)], by = "pid", all.x = TRUE)
    s[, `:=`(hpv_binary = fcase(hpv_rna == "pos", "HPV_pos", hpv_rna == "neg", "HPV_neg"), hpv_evidence_level = "B")]
  } else {
    log_msg("[注意] 無 tcga_hnsc_hpv_rna_status.csv → 使用 ISH（Level C）優先、p16（Level D）其次；結果需標註為 surrogate")
    ish <- tolower(col_or_na(s, "hpv_status_by_ish_testing")); p16 <- tolower(col_or_na(s, "hpv_status_by_p16_testing"))
    s[, hpv_binary := fcase(ish == "positive", "HPV_pos", ish == "negative", "HPV_neg",
                            p16 == "positive", "HPV_pos", p16 == "negative", "HPV_neg")]
    s[, hpv_evidence_level := fcase(!is.na(ish) & ish %in% c("positive", "negative"), "C", !is.na(hpv_binary), "D", default = "E")]
  }
  s[, `:=`(os_t = to_num(col_or_na(s, "OS.time")) / 30.44, os_e = as.integer(to_num(col_or_na(s, "OS"))),
           pfs_t = to_num(col_or_na(s, "PFI.time")) / 30.44, pfs_e = as.integer(to_num(col_or_na(s, "PFI"))),
           age_n = to_num(col_or_na(s, "age_at_initial_pathologic_diagnosis")), sex = col_or_na(s, "gender"),
           stage = col_or_na(s, "clinical_stage", "pathologic_stage"), smoking = col_or_na(s, "tobacco_smoking_history"),
           n_stage = col_or_na(s, "pathologic_N", "clinical_N"), sample_type = "tumor")]
  list(name = "TCGA-HNSC", expr = ex[, s$sample], samples = s, scores = NULL)
}

cohorts <- list(load_geo_cohort("GSE65858"), load_tcga())
cohorts <- cohorts[!sapply(cohorts, is.null)]
assert_that(length(cohorts) > 0, "沒有可用的存活資料 cohort（需先完成 GSE65858 前處理或安裝 UCSCXenaTools）")

prep_cov <- function(s) {
  s <- copy(s)
  sm <- tolower(s$smoking %||% NA); st <- toupper(s$stage %||% NA); sx <- tolower(s$sex %||% NA)
  s[, `:=`(smoking_bin = fcase(grepl("never|non|^1$|lifelong non", sm), "never", !is.na(sm) & sm != "", "ever"),
           stage_bin = fcase(grepl("IV|\\b4\\b", st), "late", grepl("III|\\b3\\b", st), "late",
                             grepl("STAGE\\s*I{1,2}[ABC]?\\b|^I{1,2}[ABC]?$|\\b[12]\\b", st), "early"),
           sex_bin = fcase(grepl("^f", sx), "F", grepl("^m", sx), "M"),
           nodal = fcase(grepl("N0", toupper(n_stage %||% NA)), 0L, grepl("N[1-3]", toupper(n_stage %||% NA)), 1L))]
  s
}

km_plot <- function(d, title) {
  fit <- survfit(Surv(time, event) ~ grp, data = d)
  if (has("survminer")) {
    p <- survminer::ggsurvplot(fit, data = d, pval = TRUE, risk.table = TRUE, palette = c("#2E86C1", "#C0392B"), title = title,
                               legend.title = "", xlab = "Months", ggtheme = theme_pub())
    return(function() print(p))
  }
  function() { plot(fit, col = c("#2E86C1", "#C0392B"), main = title, xlab = "Months"); legend("bottomleft", levels(d$grp), col = c("#2E86C1", "#C0392B"), lty = 1) }
}

res <- list(); mv_rows <- list(); ln_rows <- list()
for (co in cohorts) {
  s0 <- prep_cov(co$samples); ex <- co$expr
  feats <- list()
  for (g in intersect(CORE, rownames(ex))) feats[[display_symbol(g)]] <- ex[g, s0$gsm]
  if (!is.null(co$scores)) for (sg in intersect(c("HBP_OGlcNAc", "Mito_one_carbon", "IFNG_6gene_Ayers", "Checkpoint_PDL1", "Cytotoxic_T_NK",
                                                  "T_exhaustion", "Antigen_presentation_MHCI", "EV_biogenesis", "HPV_E2F_cell_cycle",
                                                  "OGT_minus_OGA_log2ratio"), rownames(co$scores)))
    feats[[paste0("score:", sg)]] <- co$scores[sg, s0$gsm]
  hi <- function(v) as.integer(v > median(v, na.rm = TRUE))
  if (all(c("MTHFD2", "OGT", "CD274") %in% rownames(ex))) feats[["composite:MTHFD2hi_OGThi_CD274hi"]] <- hi(ex["MTHFD2", s0$gsm]) * hi(ex["OGT", s0$gsm]) * hi(ex["CD274", s0$gsm])
  if (all(c("CORO1A", "CD274") %in% rownames(ex))) feats[["composite:CORO1Ahi_CD274hi"]] <- hi(ex["CORO1A", s0$gsm]) * hi(ex["CD274", s0$gsm])

  for (endpoint in c("OS", "PFS")) {
    tcol <- if (endpoint == "OS") "os_t" else "pfs_t"; ecol <- if (endpoint == "OS") "os_e" else "pfs_e"
    if (all(is.na(s0[[tcol]]))) next
    for (site in c("all", "oral_cavity", "oropharynx")) for (hpv in c("all", "HPV_pos", "HPV_neg")) {
      idx <- !is.na(s0[[tcol]]) & !is.na(s0[[ecol]]) & (site == "all" | s0$anatomic_site == site) & (hpv == "all" | s0$hpv_binary %in% hpv)
      s <- s0[idx]; if (nrow(s) < 20 || sum(s[[ecol]]) < 8) next
      for (fn in names(feats)) {
        x <- feats[[fn]][idx]; is_bin <- grepl("^composite", fn)
        d <- data.table(time = s[[tcol]], event = s[[ecol]], x = if (is_bin) x else as.numeric(scale(x)), hpv = s$hpv_binary,
                        site = s$anatomic_site, age = s$age_n, sex = s$sex_bin, stage = s$stage_bin, smoking = s$smoking_bin)
        d[, grp := factor(if (is_bin) ifelse(x == 1, "high", "other") else ifelse(x > median(x), "high", "low"),
                          levels = if (is_bin) c("other", "high") else c("low", "high"))]
        if (length(unique(d$grp)) < 2) next
        lr <- survdiff(Surv(time, event) ~ grp, d); lr_p <- pchisq(lr$chisq, length(lr$n) - 1, lower.tail = FALSE)
        uc <- summary(coxph(Surv(time, event) ~ x, d))
        # multivariable：只納入完整度 ≥ 80% 且有變異的共變項；EPV（events per variable）≥ 5
        covs <- c("age", "sex", "stage", "smoking", if (site == "all") "site", if (hpv == "all") "hpv")
        covs <- covs[sapply(covs, function(v) mean(!is.na(d[[v]])) >= 0.8 && length(unique(na.omit(d[[v]]))) > 1)]
        while (length(covs) && sum(d$event) / (length(covs) + 1) < 5) covs <- head(covs, -1)
        dm <- d[complete.cases(d[, c("time", "event", "x", covs), with = FALSE])]
        mv <- tryCatch(coxph(as.formula(paste("Surv(time, event) ~ x", if (length(covs)) paste("+", paste(covs, collapse = "+")))), dm), error = function(e) NULL)
        zph_p <- if (!is.null(mv)) tryCatch(cox.zph(mv)$table["x", "p"], error = function(e) NA) else NA
        inter_p <- NA
        if (hpv == "all" && length(unique(na.omit(d$hpv))) == 2) {
          di <- d[!is.na(hpv)]
          m0 <- coxph(Surv(time, event) ~ x + hpv, di); m1 <- coxph(Surv(time, event) ~ x * hpv, di)
          inter_p <- anova(m0, m1)[2, "Pr(>|Chi|)"]
        }
        rcs_p <- NA
        if (!is_bin && sum(d$event) >= 50 && has("rms")) {
          dd <- rms::datadist(d); options(datadist = dd)
          f <- tryCatch(rms::cph(Surv(time, event) ~ rms::rcs(x, 3), data = d, x = TRUE, y = TRUE), error = function(e) NULL)
          if (!is.null(f)) rcs_p <- tryCatch(anova(f)[" Nonlinear", "P"], error = function(e) NA)
        }
        mvs <- if (!is.null(mv)) summary(mv)$conf.int["x", ] else rep(NA, 4)
        res[[paste(co$name, endpoint, site, hpv, fn)]] <- data.table(
          cohort = co$name, endpoint = endpoint, site = site, hpv = hpv, feature = fn, n = nrow(d), events = sum(d$event),
          logrank_P = lr_p, uni_HR = uc$conf.int[1, 1], uni_L = uc$conf.int[1, 3], uni_U = uc$conf.int[1, 4], uni_P = uc$coefficients[1, 5],
          mv_HR = mvs[1], mv_L = mvs[3], mv_U = mvs[4], mv_P = if (!is.null(mv)) summary(mv)$coefficients["x", 5] else NA,
          mv_covariates = paste(covs, collapse = "+"), mv_n = nrow(dm), PH_P = zph_p, HPV_interaction_P = inter_p, rcs_nonlinear_P = rcs_p,
          hpv_evidence = paste(unique(s$hpv_evidence_level), collapse = "/"))
        if (fn %in% c(display_symbol(CORE), "composite:MTHFD2hi_OGThi_CD274hi", "composite:CORO1Ahi_CD274hi") && hpv == "all")
          save_fig(km_plot(d, sprintf("%s %s | %s | %s", co$name, endpoint, site, fn)),
                   paste0("Fig18_KM_", co$name, "_", endpoint, "_", site, "_", gsub("[:/ ]", "_", fn)), 6, 6, subdir = "survival")
        if (!is.null(mv) && fn %in% display_symbol(CORE) && site == "all" && hpv == "all") {
          ci <- summary(mv)$conf.int
          mv_rows[[paste(co$name, endpoint, fn)]] <- data.table(cohort = co$name, endpoint = endpoint, feature = fn, term = rownames(ci),
                                                                HR = ci[, 1], L = ci[, 3], U = ci[, 4], P = summary(mv)$coefficients[, 5])
        }
      }
    }
  }
  # 淋巴結轉移
  if (any(!is.na(s0$nodal))) for (fn in names(feats)) {
    d <- data.table(y = s0$nodal, x = as.numeric(scale(feats[[fn]])), site = s0$anatomic_site, hpv = s0$hpv_binary)[complete.cases(y, x)]
    if (nrow(d) < 30) next
    m <- tryCatch(glm(y ~ x + site + hpv, d[complete.cases(d)], family = binomial), error = function(e) NULL)
    if (!is.null(m) && "x" %in% rownames(coef(summary(m))))
      ln_rows[[paste(co$name, fn)]] <- data.table(cohort = co$name, feature = fn, OR_perSD = exp(coef(m)["x"]), P = coef(summary(m))["x", 4], n = nrow(d))
  }
}
R <- rbindlist(res)
assert_that(nrow(R) > 0, "沒有任何存活分析可執行（樣本或事件數不足）")
R[, `:=`(uni_FDR = p.adjust(uni_P, "BH"), mv_FDR = p.adjust(mv_P, "BH")), by = .(cohort, endpoint, site, hpv)]
safe_fwrite(R, pp("tables", "Table_14_survival_all.csv"))
if (length(ln_rows)) safe_fwrite(rbindlist(ln_rows)[, FDR := p.adjust(P, "BH"), by = cohort], pp("tables", "Table_15_lymph_node_association.csv"))
MV <- rbindlist(mv_rows)
if (nrow(MV)) {
  safe_fwrite(MV, pp("tables", "Table_16_multivariable_cox_terms.csv"))
  p <- ggplot(MV, aes(HR, term, xmin = L, xmax = U)) + geom_vline(xintercept = 1, lty = 2) + geom_errorbarh(height = 0.2) + geom_point(color = "#C0392B") +
    scale_x_log10() + facet_wrap(cohort + endpoint ~ feature, scales = "free_y") + labs(x = "Hazard ratio (log scale; gene per 1 SD)", y = NULL,
    title = "Multivariable Cox models (association only)") + theme_pub(8)
  save_fig(p, "Fig19_multivariable_Cox_forest", 12, 8, subdir = "survival")
}
finish_script("11_survival")
