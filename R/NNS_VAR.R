#' NNS VAR
#'
#' Nonparametric vector autoregressive model incorporating \link{NNS.ARMA} estimates of variables into \link{NNS.reg} for a multi-variate time-series forecast.
#'
#' @param variables a numeric matrix or data.frame of contemporaneous time-series to forecast.
#' @param h integer; 1 (default) Number of periods to forecast.
#' @param tau integer; 0 (default) Number of lagged observations to consider for the time-series data.
#' @param obj.fn expression;
#' \code{expression(sum((predicted - actual)^2))} (default) Sum of squared errors is the default objective function.  Any \code{expression()} using the specific terms \code{predicted} and \code{actual} can be used.
#' @param objective options: ("min", "max") \code{"min"} (default) Select whether to minimize or maximize the objective function \code{obj.fn}.
#' @param status logical; \code{TRUE} (default) Prints status update message in console.
#' @param ncores integer; value specifying the number of cores to be used in the parallelized subroutine \link{NNS.reg}. If NULL (default), the number of cores to be used is equal to half the number of cores of the machine - 1.
#' @param subcores integer; value specifying the number of cores to be used in the parallelized procedure in the subroutine \link{NNS.ARMA.optim}.  If NULL (default), the number of cores to be used is equal to half the number of cores of the machine - 1.
#'
#' @return Returns a matrix of forecasted variables.
#'
#' @author Fred Viole, OVVO Financial Systems
#' @references Viole, F. and Nawrocki, D. (2013) "Nonlinear Nonparametric Statistics: Using Partial Moments"
#' \url{http://amzn.com/1490523995}
#'
#' Viole, F. (2019) "Forecasting Using NNS"
#' \url{https://ssrn.com/abstract=3382300}
#'
#' Vinod, H. and Viole, F. (2017) "Nonparametric Regression Using Clusters"
#' \url{https://link.springer.com/article/10.1007/s10614-017-9713-5}
#'
#' Vinod, H. and Viole, F. (2018) "Clustering and Curve Fitting by Line Segments"
#' \url{https://www.preprints.org/manuscript/201801.0090/v1}
#' @examples
#'
#'  \dontrun{
#'  set.seed(123)
#'  x <- rnorm(100) ; y <- rnorm(100) ; z <- rnorm(100)
#'  A <- cbind(x = x, y = y, z = z)
#'  NNS.VAR(A, h = 12, tau = 4, status = TRUE)
#'  }
#'
#' @export



NNS.VAR <- function(variables,
                    h,
                    tau = 0,
                    obj.fn = expression( sum((predicted - actual)^2) ),
                    objective = "min",
                    status = TRUE,
                    ncores = NULL,
                    subcores = NULL){


# Create train / test sets for NNS.ARMA extensions
  train_VAR = dim(variables)[1] - h
  test_DVs = tail(variables, h)

  nns_IVs <- list()

  # Parallel process...
  if (is.null(ncores)) {
    cores <- detectCores()
    num_cores <- as.integer(cores / 2)
  } else {
    cores <- detectCores()
    num_cores <- ncores
  }

  if (is.null(subcores)) {
    subcores <- as.integer(cores / 2) - 1
  }

  cl <- makeCluster(detectCores()-1)
  registerDoParallel(cl)

  if(status){
    message("Currently generating univariate estimates...","\r", appendLF=TRUE)
  }

  nns_IVs <- foreach(i = 1:ncol(variables), .packages = 'NNS')%dopar%{
    variable <- variables[, i]

    periods <- NNS.seas(variable, modulo = tau,
                        mod.only = FALSE, plot = FALSE)$periods

    b <- NNS.ARMA.optim(variable, seasonal.factor = periods,
                       training.set = length(variable) - 2*h,
                       obj.fn = obj.fn,
                       objective = objective,
                       print.trace = status,
                       ncores = subcores)

    NNS.ARMA(variable, h = h, seasonal.factor = b$periods, weights = b$weights,
             method = b$method, ncores = ncores, plot = FALSE) + b$bias.shift
  }

  stopCluster(cl)
  registerDoSEQ()

  nns_IVs <- do.call(cbind, nns_IVs)

# Combine forecasted IVs onto training data.frame
  new_values <- rbind(variables, nns_IVs)

# Now lag new forecasted data.frame
  lagged_new_values <- lag.mtx(new_values, tau = tau)

# Select tau = 0 as test set DVs
  DVs <- which(grepl("tau.0", colnames(lagged_new_values)))

  nns_DVs <- list()

  if(status){
    message("Currently generating multi-variate estimates...","\r",appendLF=TRUE)
  }

  for(i in DVs){
    index <- which(DVs%in%i)
    if(status){
      message("Variable ", index, " of ", length(DVs), appendLF=TRUE)
    }
# NNS.boost() is an ensemble method comparable to xgboost, and aids in dimension reduction
    nns_boost_est <- NNS.boost(lagged_new_values[, -i], lagged_new_values[, i],
                               IVs.test = tail(lagged_new_values[, -i], h),
                               obj.fn = obj.fn,
                               objective = objective,
                               learner.trials = 100, epochs = 100,
                               ncores = ncores, type = NULL,
                               feature.importance = FALSE)

# NNS.stack() cross-validates the parameters of the multivariate NNS.reg() and dimension reduction NNS.reg()
    nns_DVs[[index]] <- NNS.stack(lagged_new_values[, names(nns_boost_est$feature.weights)%in%colnames(lagged_new_values)],
                             lagged_new_values[, i],
                             IVs.test =  tail(lagged_new_values[, names(nns_boost_est$feature.weights)%in%colnames(lagged_new_values)], h),
                             obj.fn = obj.fn,
                             objective = objective,
                             status = status)$stack


  }

  nns_DVs <- do.call(cbind, nns_DVs)

  forecasts <- (nns_IVs + nns_DVs)/2
  colnames(forecasts) <- colnames(variables)

  return( forecasts )

}