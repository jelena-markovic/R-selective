# Functions to fit and "infer" about parameters in the
# randomized LASSO
#
# min 1/2 || y - \beta_0 - X \beta ||_2^2 + \lambda || \beta ||_1 - \omega^T\beta + \frac{\epsilon}{2} \|\beta\|^2_2

randomizedLasso = function(X, 
                           y, 
                           lam, 
                           family=c("gaussian","binomial"),
                           condition_subgrad=TRUE,
                           noise_scale=NULL, 
                           ridge_term=NULL, 
                           max_iter=100,        # how many iterations for each optimization problem
                           kkt_tol=1.e-4,       # tolerance for the KKT conditions
                           parameter_tol=1.e-8, # tolerance for relative convergence of parameter
                           objective_tol=1.e-8, # tolerance for relative decrease in objective
                           objective_stop=FALSE,
                           kkt_stop=TRUE,
                           parameter_stop=TRUE)
{
    family = match.arg(family)

    n = nrow(X); p = ncol(X)
    y = as.vector(y)

    mean_diag = mean(apply(X^2, 2, sum))

    # default ridge term

    if (is.null(ridge_term)) {
        ridge_term = sqrt(mean_diag) * sd(y) / sqrt(n)
    }

    # default noise level

    if (is.null(noise_scale)) {
        if (family == "gaussian") {
            noise_scale = 0.5 * sd(y) * sqrt(mean_diag)
        } else if (family == "binomial") {
	    noise_scale = 0.5 * sd(y) * sqrt(mean_diag) 
        }
    }
    
    if (noise_scale > 0) {
        perturb_ = rnorm(p) * noise_scale
    } else {
        perturb_ = rep(0, p)
    }

    lam = as.numeric(lam)
    if (length(lam) == 1) {
       lam = rep(lam, p)
    }

    if (length(lam) != p) {
       stop("Lagrange parameter should be single float or of length ncol(X)")
    }    

    if (family=="gaussian"){
      soln = rep(0, p)
      Xsoln = rep(0, n)
      linear_func = (- y %*% X - perturb_) / n

      gradient = 1. * linear_func
      ever_active = as.integer(rep(0, p))
      nactive = as.integer(0)
      
      result = solve_QP_wide(X,                  # design matrix
                           lam / n,            # vector of Lagrange multipliers
                           ridge_term / n,     # ridge_term 
                           max_iter, 
                           soln, 
                           linear_func, 
                           gradient, 
                           Xsoln,
                           ever_active, 
                           nactive, 
                           kkt_tol, 
                           objective_tol, 
                           parameter_tol,
                           p,
                           objective_stop,     # objective_stop
                           kkt_stop,           # kkt_stop
                           parameter_stop)         # param_stop
    } else if (family=="binomial"){
      result = solve_logistic(X, 
                              y, 
                              lam, 
                              ridge_term, 
                              perturb_,
                              niters=5,
                              max_iter=max_iter,        # how many iterations for each optimization problem
                              kkt_tol=kkt_tol,       # tolerance for the KKT conditions
                              parameter_tol=parameter_tol, # tolerance for relative convergence of parameter
                              objective_tol=objective_tol, # tolerance for relative decrease in objective
                              objective_stop=objective_stop,
                              kkt_stop=kkt_stop,
                              parameter_stop=parameter_stop)
    }
    #print("SOLN")
    #print(result$soln)
    print(c("nactive", length(which(result$soln!=0))))
    
    sign_soln = sign(result$soln)
    unpenalized = lam == 0
    active = (!unpenalized) & (sign_soln != 0)
    inactive = (!unpenalized) & (sign_soln == 0)

    unpenalized_set = which(unpenalized)
    active_set = which(active)
    inactive_set = which(inactive)

    # observed opt state

    observed_scalings = abs(result$soln)[active]
    observed_unpen = result$soln[unpenalized]
    observed_subgrad = -n*result$gradient[inactive]
    
    if (sum(abs(observed_subgrad)>lam[inactive]*(1.001)) > 0){
      stop("subgradient eq not satisfied")
    }

    observed_opt_state = c(observed_unpen, observed_scalings, observed_subgrad)

    # affine transform for optimization variables

    E = c(unpenalized_set, active_set)
    I = inactive_set
    X_E = X[,E]

    if (length(E)==0){
      return(list(active_set=c()))
    }
    
    if (family=="binomial"){
      unpen_reg = glm(y~X_E-1, family="binomial")
      unpen_est = unpen_reg$coefficients
      pi_vec = logistic_fitted(X_E, unpen_est)
      W_E = diag(pi_vec*(1-pi_vec))
    } else if (family=="gaussian"){
      W_E = diag(rep(1,n))
      unpen_reg = glm(y ~ X_E-1)
    }
    
    observed_internal =  c(as.vector(unpen_reg$coefficients), as.vector((y - fitted(unpen_reg)) %*% X)[inactive_set])
    
    
    L_E = t(X_E) %*% W_E %*% X
    L_E = t(L_E)
    coef_term = L_E

    signs_ = c(rep(1, sum(unpenalized)), sign_soln[active])
    
    coef_term[active,] = coef_term[active,] + ridge_term * diag(rep(1, sum(active)))  # ridge term
  
    if (length(signs_) == 1) {
      coef_term = coef_term * signs_
    } else {
      coef_term = coef_term %*% diag(signs_)  # scalings are non-negative
    }
    
    if (sum(inactive) > 0) {
        if (condition_subgrad == FALSE) {
            subgrad_term = matrix(0, p, sum(inactive)) # for subgrad
            for (i in 1:sum(inactive)) {
                subgrad_term[inactive_set[i], i] = 1
                }
            linear_term = cbind(coef_term,
                                subgrad_term)
        } else {
            linear_term = coef_term
        }
    } else {
        linear_term = coef_term
    }    
    offset_term = rep(0, p)
    offset_term[active] = lam[active] * sign_soln[active]

    # if conditional_subgrad == TRUE, linear_term will have E columns
    # otherwise it will have p columns

    opt_transform = list(linear_term=linear_term,
                         offset_term=offset_term)

    # affine transform for internal (data) variables
    # for now just use parametric in terms of
    # (\bar{\beta}_E, X_{-E}^T(y-X_E\bar{\beta}_E)
    # 
    # we have to reconstruct -X^TY from this pair
    #

    active_term = -L_E                           # for \bar{\beta}_E

    if (sum(inactive) > 0) {
        if (condition_subgrad == FALSE) {
            inactive_term = subgrad_term
            linear_term = cbind(active_term,
                                inactive_term)
        } else {
            linear_term = active_term
        }
    } else {
        linear_term = active_term
    }
  
    offset_term = rep(0, p)

    # if conditional_subgrad == FALSE, linear_term will have E columns
    # otherwise it will have p columns

    internal_transform = list(linear_term=linear_term,
                              offset_term=offset_term)

    # density for sampling optimization variables
    
    if (family=="binomial"){
      unpen_est = as.vector(glm(y~X_E-1, family="binomial")$coefficients)
      observed_raw = -as.vector((y-logistic_fitted(X_E, unpen_est)) %*% X) - L_E %*% unpen_est
    } else if (family=="gaussian"){
      observed_raw = -as.vector(y %*% X)
    }
    inactive_lam = lam[inactive_set]
    inactive_start = sum(unpenalized) + sum(active)
    active_start = sum(unpenalized)
    
    log_optimization_density = function(opt_state) {

        if ((sum(abs(opt_state[(inactive_start + 1):p]) > inactive_lam) > 0) ||
            (sum(opt_state[(active_start + 1):inactive_start] < 0) > 0)) {
            return(-Inf)
        }

        D = log_density_gaussian_conditional_(noise_scale,
                                              opt_transform$linear_term,
                                              as.matrix(opt_state),
                                              observed_raw + opt_transform$offset_term)

        return(D)
    }

    # work out conditional density and save it as well

    if (condition_subgrad == TRUE) {

        constraints = matrix(0, length(active_set), 2)
        constraints[,2] = Inf

        conditional_law = conditional_opt_transform(noise_scale, 
                                                    active_set,
                                                    inactive_set,
                                                    observed_subgrad,
                                                    observed_raw,
                                                    opt_transform$linear_term,
                                                    opt_transform$offset_term,
                                                    observed_opt_state)
        conditional_law$constraints = constraints
        law = conditional_law
    } else {

        constraints = matrix(0, length(active_set), 2)
        constraints[,2] = Inf

        subgrad_constraints = cbind(-lam[inactive_set], lam[inactive_set])
        constraints = rbind(constraints, subgrad_constraints)

        full_law = list(sampling_transform=list(linear_term=opt_transform$linear_term,
                                                offset_term=opt_transform$offset_term + observed_raw),
                        constraints=constraints,
                        observed_opt_state=observed_opt_state,
                        log_optimization_density=log_optimization_density,
                        importance_transform=opt_transform)
        law = full_law
    }

    return(list(X=X,
                y=y,
                lam=lam,
                family=family,
                active_set=active_set,
                inactive_set=inactive_set,
                unpenalized_set=unpenalized_set,
                sign_soln=sign_soln,
                law=law,
                internal_transform=internal_transform,
	        observed_internal=observed_internal,
                observed_raw=observed_raw,
                noise_scale=noise_scale,
                soln=result$soln,
                perturb=perturb_,
                condition_subgrad=condition_subgrad,
		ridge_term=ridge_term
                ))

}

sample_opt_variables = function(law, jump_scale, nsample=10000) {
      return(MCMC(law$log_optimization_density, 
                  nsample,
                  law$observed_opt_state,
                  acc.rate=0.2,
                  scale=jump_scale))
}

# Carry out a linear decompositon of an internal
# representation with respect to a target

# Returns an affine transform into raw coordinates (i.e. \omega or randomization coordinates)

linear_decomposition = function(observed_target,
                                observed_internal,
                                var_target,
                                cov_target_internal,
                                internal_transform) {
    var_target = as.matrix(var_target) 
    if (nrow(var_target) == 1) {
        nuisance = observed_internal - cov_target_internal * observed_target / var_target
        target_linear = internal_transform$linear_term %*% cov_target_internal / var_target[1,1]
    } else {
        nuisance = observed_internal - cov_target_internal %*% solve(var_target) %*% observed_target 
        target_linear = internal_transform$linear_term %*% cov_target_internal %*% solve(var_target)
    }
    target_offset = internal_transform$linear_term %*% nuisance + internal_transform$offset_term
    return(list(linear_term=target_linear,
                offset_term=target_offset))
}

# XXX only for Gaussian so far

importance_weight = function(noise_scale,
                             target_sample,
                             opt_sample,
                             opt_transform,
                             target_transform,
                             observed_raw) {

    log_num = log_density_gaussian_(noise_scale,
                                    target_transform$linear_term,
                                    as.matrix(target_sample),
                                    opt_transform$linear_term,
                                    as.matrix(opt_sample),
                                    target_transform$offset_term + opt_transform$offset_term)

    log_den = log_density_gaussian_conditional_(noise_scale,
                                                opt_transform$linear_term,
                                                as.matrix(opt_sample),
                                                observed_raw + opt_transform$offset_term)

    W = log_num - log_den
    W = W - max(W)
    W = exp(W)
    W = W / sum(W)
    return(W)
}

get_mean_cov = function(noise_scale, linear_term, offset_term){
    temp = solve(t(linear_term) %*% linear_term)
    cov = noise_scale^2*temp
    mean = temp %*% t(linear_term) %*% offset_term
    return(list(mean=mean, cov=cov))
}
                             
conditional_opt_transform = function(noise_scale, 
                                     active_set,
                                     inactive_set,
                                     observed_inactive_subgrad,
                                     observed_raw,
                                     opt_linear,
                                     opt_offset,
                                     observed_opt_state) {
  
 
  nactive = length(active_set)
  B = opt_linear
  beta_offset = opt_offset
  p = length(observed_opt_state)

  if (nactive < p) {
    beta_offset[inactive_set] = beta_offset[inactive_set] + observed_inactive_subgrad
  }
  opt_transform = list(linear_term=B, 
                       offset_term=beta_offset)
  reduced_B = chol(t(B) %*% B)
  beta_offset = beta_offset + observed_raw

  reduced_beta_offset = solve(t(reduced_B)) %*% (t(B) %*% beta_offset)

  cond_cov = solve(t(B) %*% B) * noise_scale^2
  cond_mean = - cond_cov %*% t(B) %*% beta_offset / noise_scale^2

  log_condl_optimization_density = function(opt_state) {

    if  (sum(opt_state < 0) > 0) {
      return(-Inf)
    }

    log_den = log_density_gaussian_conditional_(noise_scale,
                                                reduced_B,
                                                as.matrix(opt_state),
                                                reduced_beta_offset)
    return(log_den)
  }

  log_optimization_density = log_condl_optimization_density
  observed_opt_state = observed_opt_state[1:nactive]

  reduced_opt_transform =list(linear_term = reduced_B, offset_term = reduced_beta_offset)
  return(list(sampling_transform=reduced_opt_transform,
              log_optimization_density=log_condl_optimization_density,
              observed_opt_state=observed_opt_state[1:nactive],
	      importance_transform=opt_transform,
	      cond_cov=cond_cov,
	      cond_mean=cond_mean))
}


compute_target = function(rand_lasso_soln, 
                          type, debias_mat = "JM",
                          sigma_est=1,
                          construct_pvalues=NULL,
                          construct_ci=NULL){
  
  # compute internal representation of the data
  y = rand_lasso_soln$y
  X = rand_lasso_soln$X
  p=ncol(X); n=nrow(X);
  active_set = rand_lasso_soln$active_set
  unpenalized_set = rand_lasso_soln$unpenalized_set
  nactive = length(c(active_set, unpenalized_set))
  inactive_set = rand_lasso_soln$inactive_set
  
  X_E = rand_lasso_soln$X[, c(active_set, unpenalized_set), drop=FALSE]
  
  if (rand_lasso_soln$family == 'gaussian') {
    glm_y = glm(y ~ X_E-1)
    sigma_res = sigma(glm_y)
    glm_cov = vcov(glm_y)*sigma_est^2/(sigma_res^2)
  } else if (rand_lasso_soln$family == 'binomial') {
    glm_y = glm(y ~ X_E-1, family=binomial())
    glm_cov = vcov(glm_y)
  }
  
  if (type=="partial"){
    
    observed_target = as.vector(glm_y$coefficients)
    cov_target = glm_cov
    
    if (sum(is.na(observed_target)) > 0) {
      stop("unregularized (relaxed) fit has NA values -- X[,active_set] likely singular")
    }
    
    crosscov_target_internal=rbind(cov_target, matrix(0, nrow=p-nactive, ncol=nactive))
  } 
  #print("signs")
  #print(rand_lasso_soln$sign_soln)
  alternatives = c()
  for (i in 1:length(rand_lasso_soln$sign_soln)) {
      if (rand_lasso_soln$sign_soln[i] == 1) {
          alternatives = c(alternatives, 'greater')
      } else {
          alternatives = c(alternatives, 'less')
      }
  }

  if (type=="full"){
    
    lasso.est = rand_lasso_soln$soln
    X_active = X[, active_set]
    X_inactive = X[, inactive_set]
    
    if (n<p){
  
      Mh = selectiveInference:::affine_approximate(X, lasso.est, active_set, lambda=0, debias_mat=debias_mat, linesearch.try=10)
      M_active = Mh$M  ## |E| \times n
      cov_target = sigma_est^2*M_active %*% t(M_active)
      
    }
    else{
      pseudo_invX = pinv(crossprod(X))
      M_active = pseudo_invX[active_set,] %*% t(X)
      cov_target = sigma_est^2*pseudo_invX[active_set,active_set]
    }

    residuals = y-X%*%lasso.est
    observed_target = lasso.est[active_set]+M_active %*% residuals
    pseudo_invXactive = solve(t(X_active) %*% X_active) %*% t(X_active)
    projection_Xactive = X_active %*% pseudo_invXactive # n\times n
    crosscov_target_internal = sigma_est^2*rbind(pseudo_invXactive %*% t(M_active), 
                                                 t(X_inactive) %*% (diag(n)- projection_Xactive) %*% t(M_active))
  }
  
  if (!is.null(colnames(X))) {
    names(observed_target) = colnames(X)[active_set]
  } else {
    names(observed_target) = active_set
  }
  
  targets = list(observed_target=observed_target,
                 cov_target=cov_target,
                 crosscov_target_internal=crosscov_target_internal)
  
  if (is.null(construct_ci)){
    construct_ci=rep(1,nactive)
  }
  if (is.null(construct_pvalues)){
    construct_pvalues=rep(1, nactive)
  }
  
  
  return(list(targets=targets,
              construct_ci=construct_ci, 
              construct_pvalues=construct_pvalues,
              alternatives=alternatives[active_set]))
}


randomizedLassoInf = function(rand_lasso_soln,
                              targets=NULL,
                              level=0.9,
                              sampler=c("norejection", "adaptMCMC"),
                              nsample=10000,
                              burnin=2000)
 {

  n = nrow(rand_lasso_soln$X)
  p = ncol(rand_lasso_soln$X)
  
  active_set = rand_lasso_soln$active_set
  unpenalized_set = rand_lasso_soln$unpenalized_set
  nactive = length(c(active_set, unpenalized_set))

  if (nactive==0){
    return (list(active_set=active_set, unpenalized_set=unpenalized_set, pvalues=c(), ci=c()))
  }
  inactive_set = rand_lasso_soln$inactive_set
  noise_scale = rand_lasso_soln$noise_scale  # set to default value in randomizedLasso
   
  ndim = length(rand_lasso_soln$observed_opt_state)
  
  sampler = match.arg(sampler)

  law = rand_lasso_soln$law

  if (sampler == "adaptMCMC"){
    S = sample_opt_variables(law, 
                             jump_scale=rep(1/sqrt(n), length(law$observed_opt_state)), nsample=nsample)
    opt_samples = as.matrix(S$samples[(burnin+1):nsample,,drop=FALSE])
  } else if (sampler == "norejection") {
    opt_samples = gaussian_sampler(noise_scale, 
                                   law$observed_opt_state, 
                                   law$sampling_transform$linear_term,
                                   law$sampling_transform$offset_term,
                                   law$constraints,
                                   nsamples=nsample,
		                   burnin=burnin)
  }

  if (is.null(targets)){
    targets = compute_target(rand_lasso_soln, type="partial")
  }
  
  alternatives = targets$alternatives
  construct_ci = targets$construct_ci
  construct_pvalues = targets$construct_pvalues
  targets = targets$targets
     		  
  observed_internal = rand_lasso_soln$observed_internal
  
  importance_transform = law$importance_transform
  internal_transform=rand_lasso_soln$internal_transform
  observed_raw=rand_lasso_soln$observed_raw

  pvalues = rep(0, nactive)
  ci = matrix(0, nactive, 2)
  
  names(pvalues) = names(targets$observed_target)
  rownames(ci) = names(targets$observed_target)

  for (i in 1:nactive){
    pre_nuisance = observed_internal - (as.vector(targets$crosscov_target_internal[,i]) *
                                        targets$observed_target[i] / 
                                        targets$cov_target[i,i])
    
    nuisance = internal_transform$linear_term %*% pre_nuisance[1:nactive] 
    nuisance[inactive_set] = nuisance[inactive_set] - pre_nuisance[(nactive+1):p]

    pre_linear_term = targets$crosscov_target_internal[,i] / targets$cov_target[i,i]
    linear_term = rep(0, p)
    linear_term = internal_transform$linear_term %*% pre_linear_term[1:nactive]
    linear_term[inactive_set] = linear_term[inactive_set] - pre_linear_term[(nactive+1):p]
    target_transform = list(linear_term=linear_term,
                            offset_term=as.vector(nuisance + internal_transform$offset_term)) # internal_transform$offset_term is 0...
    
    # compute sufficient statistic for root finding

    target_sample = rnorm(nrow(as.matrix(opt_samples))) * sqrt(targets$cov_target[i,i])

    # weight in the numerator is of the form
    # -1/(2 noise_scale^2)\|Do + q + P(t+\theta)\|^2_2 
    # with D=importance_transform$linear_term
    #      q=target_transform$offset_term + importance_transform$offset_term
    #      P=target_transform$linear_term

    # weight in the denominator is of the form
    # -1/(2 noise_scale^2)\|Do + q_D\|^2_2  
    # with D=importance_transform$linear_term
    #      q_D = observed_raw + importance_transform$offset_term

    # reference measure just is the ratio at \theta=0
    # sufficient statistic is linear term in \theta

    den = importance_transform$linear_term %*% t(opt_samples) + observed_raw + importance_transform$offset_term

    num1 = (importance_transform$linear_term %*% t(opt_samples) + 
            target_transform$linear_term %*% t(as.matrix(target_sample)) + 
            importance_transform$offset_term +
            target_transform$offset_term)
    num2 = (importance_transform$linear_term %*% t(opt_samples) + 
            target_transform$linear_term %*% t(as.matrix(target_sample) + 1) +
            importance_transform$offset_term +
            target_transform$offset_term)

    sufficient_stat = -apply(num2^2 - num1^2, 2, sum) / (2 * noise_scale^2)

    reference_measure = importance_weight(noise_scale,
                                          t(as.matrix(target_sample)),
                                          t(opt_samples),
                                          importance_transform,
                                          target_transform,
                                          observed_raw)
    log_reference_measure = log(reference_measure)	       

#     alternative_measure = importance_weight(noise_scale,
#                                             t(as.matrix(target_sample) + 0.1 * sqrt(targets$cov_target[i,i])),
#                                             t(opt_samples),
#                                             importance_transform,
#                                             target_transform,
#                                             observed_raw)


#     sufficient_stat = (log(alternative_measure) - log_reference_measure) / (0.1 * sqrt(targets$cov_target[i,i]))

    pivot = function(candidate){
      arg_ = candidate * sufficient_stat + log_reference_measure
      arg_ = arg_ - max(arg_)
      weights = exp(arg_)
      p = mean((target_sample + candidate <= targets$observed_target[i]) * weights)/mean(weights)
      return(p)
    }

    rootU = function(candidate){
      return (pivot(targets$observed_target[i]+candidate)-(1-level)/2)
    }

    rootL = function(candidate){
      return(pivot(targets$observed_target[i]+candidate)-(1+level)/2)
    }

    if (construct_pvalues[i]==1){
      #print(alternatives[i])
      pvalues[i] = pivot(0)
      if (alternatives[i]=="two-sided"){
        pvalues[i] = 2*min(pvalues[i], 1-pvalues[i])
      } else if (alternatives[i]=="greater"){
        pvalues[i]= 1-pvalues[i]
      }
    }
    
    if (construct_ci[i]==1){
      
      line_min = -10*sd(target_sample) + targets$observed_target[i]
      line_max = 10*sd(target_sample) + targets$observed_target[i]
    
      if (rootU(line_min)*rootU(line_max)<0){
        ci[i,2] = uniroot(rootU, c(line_min, line_max))$root + targets$observed_target[i]
      } else{
        ci[i,2]=line_max
      }
      if (rootL(line_min)*rootL(line_max)<0){
        ci[i,1] = uniroot(rootL, c(line_min, line_max))$root + targets$observed_target[i]
      } else{
        ci[i,1] = line_min
      }
    }
  }
  return(list(targets=targets, pvalues=pvalues, ci=ci))
}

logistic_fitted = function(X, beta){
  temp = X %*% as.matrix(beta)
  return(as.vector(exp(temp)/(1+exp(temp)))) # n-dimensional
}
   
solve_logistic=function(X, 
                        y, 
                        lam, 
                        ridge_term, 
                        perturb,
                        niters=5,
                        max_iter=100,        # how many iterations for each optimization problem
                        kkt_tol=1.e-4,       # tolerance for the KKT conditions
                        parameter_tol=1.e-8, # tolerance for relative convergence of parameter
                        objective_tol=1.e-8, # tolerance for relative decrease in objective
                        objective_stop=FALSE,
                        kkt_stop=TRUE,
                        parameter_stop=TRUE){

  n=nrow(X); p=ncol(X)
  soln = rep(0, p)
  ever_active = as.integer(rep(0, p))
  nactive = as.integer(0)
  
  lam = as.numeric(lam)
  if (length(lam) == 1) {
       lam = rep(lam, p)
  }
  
  for (i in 1:niters){
    pi_vec = logistic_fitted(X, soln)
    rootW = diag(sqrt(as.vector(pi_vec*(1-pi_vec))))
    weighted_X = rootW %*% X
    Xsoln = weighted_X %*% soln
    
    gradient = -t(X)%*%(y-pi_vec)-perturb
    linear_func = gradient-t(weighted_X) %*% weighted_X %*% as.vector(soln)
    gradient = gradient/n
    linear_func = linear_func/n
    
    result = solve_QP_wide(weighted_X,                  # design matrix
                           lam / n,            # vector of Lagrange multipliers
                           ridge_term / n,     # ridge_term 
                           max_iter, 
                           soln, 
                           linear_func, 
                           gradient, 
                           Xsoln,
                           ever_active, 
                           nactive, 
                           kkt_tol, 
                           objective_tol, 
                           parameter_tol,
                           p,
                           objective_stop,     # objective_stop
                           kkt_stop,           # kkt_stop
                           parameter_stop)         # param_stop
    
  }
  return(result)
}


    



