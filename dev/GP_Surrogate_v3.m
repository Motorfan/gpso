classdef GP_Surrogate < handle
    
    properties (SetAccess = private)
        x; % sample coordinates
        y; % data array with columns [mu,sigma,ucb]
        GP; % GP parameters
        varsigma; % controls optimism in the face of uncertainty
        
        lower;
        upper;
        
        Ne, Ng; % number of evaluated/GP-based samples
    end
    
    properties (Transient,Dependent)
        Ns; % number of samples
        Nd; % number of dimensions
        delta; % dimensions of the box
    end
    
    properties (Constant)
        LIK_BND = [-12 -1];
    end
    
    methods
        
        function self=GP_Surrogate()
            self.clear();
        end
        
        function self=clear(self)
            self.x = [];
            self.y = [];
            self.GP = struct();
            self.varsigma = nan;
            self.lower = [];
            self.upper = [];
            self.Ne = 0;
            self.Ng = 0;
        end
        
        % setters
        function self=set_gp(self, hyp, meanfunc, covfunc)
            
            gp.hyp = hyp;
            gp.likfunc = @likGauss; % Gaussian likelihood is assumed for analytics
            gp.meanfunc = meanfunc;
            gp.covfunc = covfunc;
            
            self.GP = gp;
            
        end
        
        function v=get_varsigma(self)
            v = self.varsigma(self.Ng);
        end
        function self=set_varsigma_paper(self,eta)
            % JH: original varsigma can be complex for M=1 and eta=1
            self.varsigma = @(M) sqrt(max( 0, 4*log(pi*M) - 2*log(12*eta) )); % cf Lemma 1
        end        
        function self=set_varsigma_const(self,val)
            self.varsigma = @(M) val;
        end
        
        % dependent properties
        function n = get.Ns(self), n = size(self.x,1); end
        function n = get.Nd(self), n = numel(self.lower); end
        function d = get.delta(self), d = self.upper-self.lower; end
        
        % initialisation
        function self=init(self,domain)
            
            assert( ismatrix(domain) && ~isempty(domain) && ... 
                size(domain,2)==2 && all(diff(domain,1,2) > eps), 'Bad domain.' );
        
            self.lower = domain(:,1)';
            self.upper = domain(:,2)';
            
            self.x = [];
            self.y = [];
            
            self.Ne = 0;
            self.Ng = 0;
            
        end
                
        % normalise/denormalise coordinates
        function y = normalise(self,x)
            y = bsxfun( @minus, x, self.lower );
            y = bsxfun( @rdivide, y, self.delta );
        end
        function y = denormalise(self,x)
            y = bsxfun( @times, x, self.delta );
            y = bsxfun( @plus, y, self.lower );
        end
        
        % append new samples
        % WARNING: by default, assumes x is NORMALISED
        function k=append(self,x,m,s,isnorm)
            
            n = numel(m); % number of input samples
            if nargin < 4, s=zeros(n,1); end
            if nargin < 5, isnorm=true; end
            
            if isscalar(s) && n>1, s=s*ones(n,1); end
            assert( size(x,1)==n && numel(s)==n, 'Size mismatch.' );
            assert( all(s >= 0), 'Sigma should be non-negative.' );
            
            k = self.Ns + (1:n); % index of new samples
            m = m(:);
            s = s(:);
            
            if ~isnorm, x = self.normalise(x); end
            self.x = [self.x; x ];
            self.y = [self.y; [m,s,m] ];
            
            g = nnz(s);
            self.Ng = self.Ng + g;
            self.Ne = self.Ne + n-g;
            
        end
        function k = append2(self,x,y,isnorm)
            
            n = size(x,1); 
            if nargin < 4, isnorm=true; end
            assert( size(y,1)==n, 'Size mismatch.' );
            
            k = self.Ns + (1:n);
            g = nnz(y(:,2));
            
            if ~isnorm, x = self.normalise(x); end
            self.x = [self.x; x ];
            self.y = [self.y; y ];
            
            self.Ng = self.Ng + g;
            self.Ne = self.Ne + n-g;
            
        end
        
        % update sample score
        function self=update(self,k,m,s)
            
            n = numel(k);
            if nargin < 4, s=zeros(n,1); end
            
            if isscalar(s) && n>1, s=s*ones(n,1); end
            assert( numel(m)==n, 'Size mismatch.' );
            assert( numel(s)==n, 'Size mismatch.' );
            
            m = m(:);
            s = s(:);
            
            g1 = nnz(self.y(k,2));
            g2 = nnz(s);
            
            self.y(k,:) = [m,s,m];
            
            self.Ne = self.Ne + g1-g2;
            self.Ng = self.Ng + g2-g1;
            
        end
        function self=update2(self,k,y)
            g1 = nnz(self.y(k,2));
            g2 = nnz(y(:,2));
            
            self.y(k,:) = y;
            
            self.Ne = self.Ne + g1-g2;
            self.Ng = self.Ng + g2-g1;
        end
        
        % evaluate surrogate at query points
        % WARNING: assumes query points xq are NOT normalised
        function [m,s] = surrogate(self,xq)
            [m,s] = self.gp_call(self.normalise(xq));
        end
        
        % serialise data to be saved
        function D = serialise(self)
            F = {'lower','upper','x','y','Ne','Ng','GP'};
            n = numel(F);
            D = struct();
            
            for i = 1:n
                f = F{i};
                D.(f) = self.(f);
            end
            D.version = '0.1';
        end
        function self=unserialise(self,D)
            F = {'lower','upper','x','y','Ne','Ng','GP'};
            n = numel(F);
            
            for i = 1:n
                f = F{i};
                self.(f) = D.(f);
            end
        end
        
    end
    
    methods
        
        % access y's columns
        function y = ycol(self,c,k)
            if nargin > 2
                y = self.y(k,c);
            else
                y = self.y(:,c);
            end
        end
        
        % aliases to y's columns
        % if called without index, returns the whole column
        function m = mu(self,varargin), m = self.ycol(1,varargin{:}); end
        function s = sigma(self,varargin), s = self.ycol(2,varargin{:}); end
        function u = ucb(self,varargin), u = self.ycol(3,varargin{:}); end
        
        % access sample coordinates
        function x = coord(self,k,denorm)
            if nargin < 3, denorm=false; end
            x = self.x(k,:);
            if denorm
                x = self.denormalise(x);
            end
        end
        
        % is GP-based
        function g = is_gp_based(self,varargin)
            g = self.sigma(varargin{:}) > 0;
        end
        
        % indices of evaluated/gp-based samples
        function k = find_evaluated(self)
            k = find( self.sigma == 0 );
        end
        function k = find_gp_based(self)
            k = find( self.sigma > 0 );
        end
        
        % access evaluated/gp-based samples
        function [x,f] = samp_evaluated(self,varargin)
            k = self.find_evaluated();
            f = self.mu(k);
            x = self.coord(k,varargin{:});
        end
        function [x,f] = samp_gp_based(self,varargin)
            k = self.find_gp_based();
            f = self.ucb(k);
            x = self.coord(k,varargin{:});
        end
        
        % best score or sample
        function [f,k] = best_score(self)
            p = self.find_evaluated();
            [f,k] = max(self.mu(p));
            k = p(k);
        end
        function [x,f] = best_sample(self,varargin)
            [f,k] = self.best_score();
            x = self.coord(k,varargin{:});
        end
        
    end
    
    methods
        
        % UCB update
        function self=ucb_update(self)
            if self.Ng > 0
                k = self.find_gp_based();
                self.y(k,3) = self.y(k,1) + self.get_varsigma() * self.y(k,2);
            end
        end
        
        % check a few things before calling gp
        function self=gp_check(self)

            % make sure GP is set
            assert( isfield(self.GP,'hyp'), 'GP has not been configured yet (see set_gp).' );
            assert( isa(self.varsigma,'function_handle'), 'Varsigma has not been set yet (see set_varsisgma*).' );
            
            % make sure GPML is on the path
            if isempty(which('gp'))
                warning('GPML library not on the path, calling gpml_start.');
                gpml_start();
            end
            
            % don't allow sigma to become too small (bad for optimisation)
            self.GP.hyp.lik = max( self.GP.hyp.lik, -15 );
        
        end
        
        % WARNING: assumes query points are NORMALISED
        function [m,s]=gp_call(self,xq)
            
            self.gp_check();
            
            err = true;
            hyp = self.GP.hyp;
            
            [xe,fe] = self.samp_evaluated();
            while err
                err = false;
                try
                    [m,s] = gp( hyp, @infExact, ...
                        self.GP.meanfunc, self.GP.covfunc, self.GP.likfunc, xe, fe, xq ...
                    );
                catch
                    err = true;
                    hyp.lik = hyp.lik + 1;
                    assert( hyp.lik < 0, 'Numerical stability error.' );
                end
            end
            
            % if sigma is 0, it will be confused with a non-gp sample
            s = max(eps,sqrt(s)); 
            
        end
        
        function self=gp_update(self)
            
            self.gp_check();
            
            [xe,fe] = self.samp_evaluated();
            self.GP.hyp = minimize( self.GP.hyp, @gp, -100, ...
                @infExact, self.GP.meanfunc, self.GP.covfunc, self.GP.likfunc, xe, fe );
            
            % don't allow sigma to become too small or too big
            self.GP.hyp.lik = dk.math.clamp( self.GP.hyp.lik, self.LIK_BND );
            
            % re-evaluate all gp-based samples
            if self.Ng > 0
                
                v = self.get_varsigma();
                k = self.find_gp_based();
                
                [m,s] = self.gp_call( self.x(k,:) );
                self.y(k,:) = [ m, s, m + v*s ];
                
            end
            
        end
        
    end
    
end
