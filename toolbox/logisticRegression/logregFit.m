function [model, varargout] = logregFit(X, y, varargin)
% Fit a logistic regression model, (support multiclass)
%% INPUTS:
% regType       ... L1 or L2
% lambda        ... regularizer (can be a range tuned via cv)
% kernelFn      ... @(X, X1, kernelParam)
% kernelParam   ... e.g. sigma in an RBF kernel (can be a range tuned via cv)
% fitMethod     ... regType dependent, e.g. minfunc
% fitOptions    ... optional fitMethod args (a struct)
% standardizeX  ... if true, call mkUnitVariance(center(X))
% rescaleX      ... if true, call rescaleData(X, scaleXrange(1), scaleXrange(2))
% scaleXrange   ... [minX, maxX], e.g. [-1 1]
% nregParams    ... number of auto-generated regularizer params to cv over
% nkernelParams ... number of auto-generated kernel params to cv over
% nfolds        ... number of folds in the cross validation
% useSErule     ... if true, pick simplest model within one stderr of best
% doPlot        ... if true, plot the cv curve or cv grid
%% OUTPUTS:
% model         ... a struct, which you can pass directly to logregPredict
% varargout{1}  ... the best parameter values chosen by CV
% varargout{2}  ... mean loss
% varargout{3}  ... standard error of varargout{2}
%% process options
args = prepareArgs(varargin); % converts struct args to a cell array
[   nclasses      ...
    regType       ...
    lambda        ...
    kernelFn      ...
    kernelParam   ...
    fitMethod     ...
    fitOptions    ...
    standardizeX  ...
    rescaleX      ...
    scaleXrange   ...
    nlambdas      ...
    nkernelParams ...
    nfolds        ...
    useSErule     ...
    doPlot        ...
    ] = process_options(args    , ...
    'nclasses'      , nunique(y), ...
    'regType'       , 'l2'      , ...
    'lambda'        ,  []       , ...
    'kernelFn'      ,  []       , ...
    'kernelParam'   ,  []       , ...
    'fitMethod'     ,  ''       , ...
    'fitOptions'    , []        , ...
    'standardizeX'  , true      , ...
    'rescaleX'      , false     , ...
    'scaleXrange'   , [-1,1]    , ...
    'nlambdas'      , 20        , ...
    'nkernelParams' , 10        , ...
    'nfolds'        , 5         , ...
    'useSErule'     , false     , ...
    'doPlot'        , false  );
%% set defaults
isbinary = nclasses < 3;
if isempty(fitMethod)
    switch lower(regType)
        case 'l1'  , fitMethod = 'l1projection';
        case 'l2'  , fitMethod = 'minfunc';
    end
end
%% preprocess X, (kernelization happens later)
pre = struct();
if standardizeX
    [X, pre.Xmu]   = center(X);
    [X, pre.Xstnd] = mkUnitVariance(X);
end
if rescaleX
    X = rescale(X, scaleXrange(1), scaleXrange(2));
    pre.Xscale = scaleXrange;
end
%%

if isbinary
    [y, ySupport] = setSupport(y, [-1 1]);
    objective = @LogisticLossSimple;
else
    [y, ySupport] = setSupport(y, 1:Nclasses);
    objective = @SoftmaxLoss2;
end

%% construct fit function
opts = fitOptions;
if isempty(opts)
    opts.Display     = 'none'; opts.TolFun = 1e-12;
    opts.MaxIter     = 5000;   opts.Method = 'lbfgs';
    opts.MaxFunEvals = 10000;  opts.TolX   = 1e-12;
end


switch lower(fitMethod)
    case 'minfunc'
        switch lower(regType)
            case 'l1' % smooth approximation
                fitCore = @(X,y,winit,l)minFunc(@penalizedL1, winit(:),opts, @(w)objective(w, X, y), l(:));
            case 'l2'
                fitCore = @(X,y,winit,l)minFunc(@penalizedL2, winit(:),opts, @(w)objective(w, X, y), l(:));
        end
    case 'l1projection'
        fitCore = @(X,y,winit,l)L1GeneralProjection(objective, winit(:), l, opts, X, y);
    case 'grafting'
        fitCore = @(X,y,winit,l)L1GeneralGrafting(objective, winit(:), l, opts, X, y);
    otherwise
        error('unrecognized fitMethod: %s', fitMethod);
end
if isempty(kernelFn)
    fitfn = @(X, y, param)simpleFit(X, y, param, fitCore, nclasses);
else
    fitfn = @(X, y, param)kernelizedFit(X, y, param(1), param(2), fitCore, kernelFn, nclasses);
end

%% constuct parameter space
if ~isempty(kernelFn) && isempty(kernelParam)
    switch func2str(kernelFn)
        case 'rbfKernel'
            kernelParam = logspace(-1, 1, nkernelParams);
        case 'kernelPoly',
            kernelParam = 1:nkernelParams;
        otherwise
            kernelParam = logspace(-1, 1, nkernelParams);
    end
end
if isempty(lambda)
    lambda = linspace(1e-5, 20, nlambdas);
end

if isempty(kernelParam)
    paramRange = lambda;
else
    paramRange = crossProduct(lambda, kernelParam);
end
%% cross validation
lossFn = @(y, yhat)mean((y-yhat).^2);
nfolds = min(size(X, 1), nfolds);
[model, varargout{1}, varargout{2}, varargout{3}] = ...
    fitCv(paramRange, fitfn, @logregPredict, lossFn, X, y, nfolds, useSErule, doPlot);

model = catstruct(model, pre);  % add preprocessor info to model
model.binary = isbinary;
model.ySupport = ySupport;
end % end of main function


function model = simpleFit(X, y, lambda, fitFn, nclasses)
% Fit function wrapper

isbinary = nclasses < 3;
X = [ones(size(X, 1), 1), X];
model.includeOffset = true;
d = size(X, 2);
lambda = lambda*ones(d, nclasses-1);
lambda(1, :) = 0; % Don't penalize bias term
winit  = zeros(d, nclasses-1);
w = fitFn(X, y, winit, lambda);
if ~isbinary
    w = [reshape(w, [d Nclasses-1]) zeros(d, 1)];
end
model.w = w;
model.binary = isbinary;
if isbinary
    model.ySupport = [-1 1];
else
    model.ySupport = 1:nclasses;
end

end

function model = kernelizedFit(X, y, lambda, kernelParam, fitfn, kernelFn, nclasses)
% Fit function wrapper

isbinary = nclasses < 3;
K = kernelFn(X, X, kernelParam);
K = [ones(size(K, 1), 1), K];
model.includeOffset = true;
d = size(K, 2);
lambda = lambda*ones(d, nclasses-1);
lambda(1, :) = 0; % Don't penalize bias term
winit  = zeros(d, nclasses-1);
w  = fitfn(K, y, winit, lambda);
if ~isbinary
    w = [reshape(w, [d Nclasses-1]) zeros(d, 1)];
end
model.w  = w;
model.basis = X;
model.kernelFn = kernelFn;
model.kernelParam = kernelParam;
model.binary = isbinary;
if isbinary
    model.ySupport = [-1 1];
else
    model.ySupport = 1:nclasses;
end

end