## Deconvolution model creation from minfi (http://bioconductor.org/packages/release/bioc/html/minfi.html) edited to take matrices rather than mset

library(genefilter)
library(quadprog)

pickCompProbes <- function(rawbetas, cellInd, cellTypes = NULL, numProbes = 50, probeSelect = probeSelectIN) {
  
  validationCellType <- function(Y, pheno, modelFix, modelBatch=NULL,
                                 L.forFstat = NULL, verbose = FALSE){
    N <- dim(pheno)[1]
    pheno$y <- rep(0, N)
    xTest <- model.matrix(modelFix, pheno)
    sizeModel <- dim(xTest)[2]
    M <- dim(Y)[1]
    
    if(is.null(L.forFstat)) {
      L.forFstat <- diag(sizeModel)[-1,] # All non-intercept coefficients
      colnames(L.forFstat) <- colnames(xTest)
      rownames(L.forFstat) <- colnames(xTest)[-1]
    }
    
    ## Initialize various containers
    sigmaResid <- sigmaIcept <- nObserved <- nClusters <- Fstat <- rep(NA, M)
    coefEsts <- matrix(NA, M, sizeModel)
    coefVcovs <- list()
    
    if(verbose)
      cat("[validationCellType] ")
    for(j in 1:M) { # For each CpG
      ## Remove missing methylation values
      ii <- !is.na(Y[j,])
      nObserved[j] <- sum(ii)
      pheno$y <- Y[j,]
      
      if(j%%round(M/10)==0 && verbose)
        cat(".") # Report progress
      
      try({ # Try to fit a mixed model to adjust for plate
        if(!is.null(modelBatch)) {
          fit <- try(lme(modelFix, random=modelBatch, data=pheno[ii,]))
          OLS <- inherits(fit,"try-error") # If LME can't be fit, just use OLS
        } else
          OLS <- TRUE
        
        if(OLS) {
          fit <- lm(modelFix, data=pheno[ii,])
          fitCoef <- fit$coef
          sigmaResid[j] <- summary(fit)$sigma
          sigmaIcept[j] <- 0
          nClusters[j] <- 0
        } else {
          fitCoef <- fit$coef$fixed
          sigmaResid[j] <- fit$sigma
          sigmaIcept[j] <- sqrt(getVarCov(fit)[1])
          nClusters[j] <- length(fit$coef$random[[1]])
        }
        coefEsts[j,] <- fitCoef
        coefVcovs[[j]] <- vcov(fit)
        
        useCoef <- L.forFstat %*% fitCoef
        useV <- L.forFstat %*% coefVcovs[[j]] %*% t(L.forFstat)
        Fstat[j] <- (t(useCoef) %*% solve(useV, useCoef))/sizeModel
      })
    }
    if(verbose)
      cat(" done\n")
    ## Name the rows so that they can be easily matched to the target data set
    rownames(coefEsts) <- rownames(Y)
    colnames(coefEsts) <- names(fitCoef)
    degFree <- nObserved - nClusters - sizeModel + 1
    
    ## Get P values corresponding to F statistics
    Pval <- 1-pf(Fstat, sizeModel, degFree)
    
    out <- list(coefEsts=coefEsts, coefVcovs=coefVcovs, modelFix=modelFix, modelBatch=modelBatch,
                sigmaIcept=sigmaIcept, sigmaResid=sigmaResid, L.forFstat=L.forFstat, Pval=Pval,
                orderFstat=order(-Fstat), Fstat=Fstat, nClusters=nClusters, nObserved=nObserved,
                degFree=degFree)
    
    out
  }
  
  
  ## p is matrix of beta values
  ## cellInd is vector denoting cell type
  splitit <- function(x) {
    split(seq(along=x), x)
  }
  
  #   p <- getBeta(mSet)
  #   pd <- as.data.frame(colData(mSet))
  if(!is.null(cellTypes)) {
    if(!all(cellTypes %in% as.character(cellInd)))
      stop("elements of argument 'cellTypes' is not part of 'cellInd'")
    keep <- which(as.character(cellInd) %in% cellTypes)
    rawbetas <- rawbetas[,keep]
    cellInd<-cellInd[keep]
  }
  ## make cell type a factor
  cellInd <- factor(cellInd)
  ffComp <- rowFtests(rawbetas, cellInd)
  prof <- sapply(splitit(cellInd), function(i) rowMeans(rawbetas[,i]))
  r <- matrixStats::rowRanges(rawbetas)
  compTable <- cbind(ffComp, prof, r, abs(r[,1] - r[,2]))
  names(compTable)[1] <- "Fstat"
  names(compTable)[c(-2,-1,0) + ncol(compTable)] <- c("low", "high", "range")
  tIndexes <- splitit(cellInd)
  tstatList <- lapply(tIndexes, function(i) {
    x <- rep(0,ncol(rawbetas))
    x[i] <- 1
    return(rowttests(rawbetas, factor(x)))
  })
  
  if (probeSelect == "any"){
    probeList <- lapply(tstatList, function(x) {
      y <- x[x[,"p.value"] < 1e-8,]
      yAny <- y[order(abs(y[,"dm"]), decreasing=TRUE),]
      c(rownames(yAny)[1:(numProbes*2)])
    })
  } else {
    probeList <- lapply(tstatList, function(x) {
      y <- x[x[,"p.value"] < 1e-8,]
      yUp <- y[order(y[,"dm"], decreasing=TRUE),]
      yDown <- y[order(y[,"dm"], decreasing=FALSE),]
      c(rownames(yUp)[1:numProbes], rownames(yDown)[1:numProbes])
    })
  }
  
  trainingProbes <- na.omit(unique(unlist(probeList)))
  rawbetas <- rawbetas[trainingProbes,]
  
  pMeans <- colMeans(rawbetas)
  names(pMeans) <- cellInd
  
  form <- as.formula(sprintf("y ~ %s - 1", paste(levels(cellInd), collapse="+")))
  phenoDF <- as.data.frame(model.matrix(~cellInd-1))
  colnames(phenoDF) <- sub("cellInd", "", colnames(phenoDF))
  if(ncol(phenoDF) == 2) { # two group solution
    X <- as.matrix(phenoDF)
    coefEsts <- t(solve(t(X) %*% X) %*% t(X) %*% t(rawbetas))
  } else { # > 2 group solution
    tmp <- validationCellType(Y = rawbetas, pheno = phenoDF, modelFix = form)
    coefEsts <- tmp$coefEsts
  }
  
  out <- list(coefEsts = coefEsts, compTable = compTable,
              sampleMeans = pMeans)
  return(out)
}
