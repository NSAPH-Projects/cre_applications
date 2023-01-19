set.seed(2022)
library("foreach")
library("doParallel")
library("cre")

# Set Experiment Parameter
experiment <- "main"  # in {'main', 'small_sample', 'more_rules',
                      #     'more_rules', 'rct', 'nonlin_conf', 'personalize'}
cutoff <- 0.8         # in [0,1]
pfer <- 1             # in (0,+inf)

if (experiment=="main") {
  n_rules <- 2
  sample_size <- 2000
  confounding <- "lin"
  dr <- c("x1>0.5 & x2<=0.5", "x5>0.5 & x6<=0.5")
  em <- c("x1","x2","x5","x6")
  max_depth <- 2
} else if (experiment=="small_sample") {
  n_rules <- 2
  sample_size <- 1000
  confounding <- "lin"
  dr <- c("x1>0.5 & x2<=0.5", "x5>0.5 & x6<=0.5")
  em <- c("x1","x2","x5","x6")
  max_depth <- 2
} else if (experiment=="more_rules") {
  n_rules <- 4
  sample_size <- 2000
  confounding <- "lin"
  dr <- c("x1>0.5 & x2<=0.5", "x5>0.5 & x6<=0.5",
          "x4>0.5", "x5<=0.5 & x7>0.5 & x8<=0.5")
  em <- c("x1","x2","x5","x6","x4","x7","x8")
  max_depth <- 3
} else if (experiment=="rct") {
  n_rules <- 2
  sample_size <- 2000
  confounding <- "no"
  dr <- c("x1>0.5 & x2<=0.5", "x5>0.5 & x6<=0.5")
  em <- c("x1","x2","x5","x6")
  max_depth <- 2
} else if (experiment=="nonlin_conf") {
  n_rules <- 2
  sample_size <- 2000
  confounding <- "nonlin"
  dr <- c("x1>0.5 & x2<=0.5", "x5>0.5 & x6<=0.5")
  em <- c("x1","x2","x5","x6")
  max_depth <- 2
} else if (experiment=="personalize") {
  n_rules <- NA
  sample_size <- NA
  confounding <- NA
  dr <- NA
  em <- NA
  max_depth <- NA
  stop("'personalize' esperiment non defined yet.")
} else {
  stop(paste("'",experiment,"' experiment doesn't exist.", sep=""))
}


# Other Setting
{
  n_seeds <- 250
  ratio_dis <- 0.5
  effect_size <- 5
  ITE_estimators <- c("aipw","cf","bcf","slearner","tlearner","xlearner","bart")

  method_params <- list(ratio_dis = ratio_dis,
                        ite_method_dis = "aipw",
                        ps_method_dis = "SL.xgboost",
                        oreg_method_dis = "SL.xgboost",
                        ite_method_inf = "aipw",
                        ps_method_inf = "SL.xgboost",
                        oreg_method_inf = "SL.xgboost")

  hyper_params <- list(intervention_vars = NULL,
                       offset = NULL,
                       ntrees_rf = 40,
                       ntrees_gbm = 40,
                       node_size = 20,
                       max_nodes = 2^max_depth,
                       max_depth = max_depth,
                       t_decay = 0.025,
                       t_ext = 0.01,
                       t_corr = 1,
                       t_pvalue = 0.05,
                       replace = TRUE,
                       stability_selection = TRUE,
                       cutoff = cutoff,
                       pfer = pfer,
                       penalty_rl = 1)
}

# Set Cluster
cl <- makeCluster(detectCores())
registerDoParallel(cl)


estimation <- data.frame(matrix(ncol = 9, nrow = 0))
# CRE
for (ite_estimator in ite_estimators){
  # CRE (estimator i)
  time.before <- proc.time()
  estimation_i <- foreach(seed = seq(1, n_seeds, 1), .combine=rbind) %dopar% {
    library("devtools")
    load_all()
    set.seed(seed)
    # Generate Dataset
    dataset <- generate_cre_dataset(n = sample_size,
                                    rho = 0,
                                    p = 10,
                                    effect_size = effect_size,
                                    n_rules = n_rules,
                                    binary_covariates = TRUE,
                                    binary_outcome = FALSE,
                                    confounding = confounding)
    y <- dataset[["y"]]
    z <- dataset[["z"]]
    X <- dataset[["X"]]
    ite <- dataset[["ite"]]
    cate <- mean(ite[X$x1 > 0.5 & X$x2 <= 0.5])
    ate <- mean(ite)

    method_params[["ite_method_dis"]] <- ite_estimator
    method_params[["ite_method_inf"]] <- ite_estimator
    result <- cre(y, z, X, method_params, hyper_params)
    ite_pred <- result$ite_pred
    cate_pred <- mean(ite_pred[X$x1 > 0.5 & X$x2 <= 0.5])
    ate_pred <- mean(ite_pred)

    ite_rmse <- sqrt(mean((ite - ite_pred)^2))
    ite_bias <- mean((ite - ite_pred))
    cate_bias <- cate - cate_pred
    ate_bias <- ate - ate_pred

    method <- paste("CRE (",ite_estimator,")", sep = "")
    betas <- c()
    for (rule in dr){
      beta <- result$CATE$Estimate[result$CATE$Rule==rule]
      betas <- c(betas,beta)
    }
    return(c(method, effect_size, seed,
             ite_rmse, ite_bias, cate_bias, ate_bias,
             betas[1], betas[2], betas[3], betas[4]))
  }
  time.after <- proc.time()
  print(paste("CRE -", ite_estimator,
              "(Time: ",round((time.after - time.before)[[3]],2), "sec)"))
  estimation <- rbind(estimation,estimation_i)
}
# Benchmarks
for (ite_estimator in ite_estimators){
  # estimator i
  time.before <- proc.time()
  estimation_i <- foreach(seed = seq(1, n_seeds, 1), .combine=rbind) %dopar% {
    library("cre")
    set.seed(seed)
    # Generate Dataset
    dataset <- generate_cre_dataset(n = sample_size,
                                    rho = 0,
                                    p = 10,
                                    effect_size = effect_size,
                                    n_rules = n_rules,
                                    binary_covariates = TRUE,
                                    binary_outcome = FALSE,
                                    confounding = confounding)
    y <- dataset[["y"]]
    z <- dataset[["z"]]
    X <- dataset[["X"]]
    ite <- dataset[["ite"]]
    cate <- mean(ite[X$x1 > 0.5 & X$x2 <= 0.5])
    ate <- mean(ite)

    ite_pred <- estimate_ite(y , z, X, ite_estimator,
                             oreg_method = "SL.xgboost",
                             ps_method = "SL.xgboost")
    cate_pred <- mean(ite_pred[X$x1 > 0.5 & X$x2 <= 0.5])
    ate_pred <- mean(ite_pred)

    ite_rmse <- sqrt(mean((ite - ite_pred)^2))
    ite_bias <- mean((ite - ite_pred))
    cate_bias <- cate - cate_pred
    ate_bias <- ate - ate_pred
    return(c(ite_estimator, effect_size, seed,
             ite_rmse, ite_bias, cate_bias, ate_bias,
             NA, NA, NA, NA))
  }
  time.after <- proc.time()
  print(paste(ite_estimator,"(Time: ",round((time.after - time.before)[[3]],2), "sec)"))
  estimation <- rbind(estimation,estimation_i)
}

colnames(estimation) <- c("method","effect_size","seed",
                          "ite_rmse","ite_bias","cate_bias","ate_bias",
                          "beta1", "beta2","beta3","beta4")
rownames(estimation) <- 1:nrow(estimation)

# Save results
results_dir <- "results/"
if (!dir.exists(results_dir)) {
  dir.create(results_dir)
}

exp_name <- paste("estimation",experiment,'cutoff',cutoff,'pfer',pfer,sep="_")
file_dir <- paste(results_dir,exp_name,".RData", sep="")
save(estimation, file=file_dir)

stopCluster(cl)
