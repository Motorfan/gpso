classdef GPSO < handle
    
    properties (SetAccess=private)
        srgt % GP surrogate
        tree % sampling tree
        iter % iteration data
        verb % verbose switch
    end
    
    events
        PostInitialise
        PostIteration
        PostUpdate
        PreFinalise
    end
    
    methods
        
        function self = GPSO()
            self.clear();
            self.configure(); % set defaults
        end
        
        function self=clear(self)
            self.srgt = GP_Surrogate();
            self.tree = GPSO_Tree();
            self.iter = {};
            self.verb = true;
        end
        
        function self=configure( self, sigma, eta )
        %
        % sigma: default 1e-4
        %   Initial log-std of Gaussian likelihood function (normalised units).
        %
        % eta: default 0.05
        %   Probability that UCB < f.
        %
        % JH
            
            if nargin < 2, sigma = 1e-4; end
            if nargin < 3, eta = 0.05; end 
            
            meanfunc = @meanConst; hyp.mean = 0;
            covfunc  = {@covMaterniso, 5}; % isotropic Matern covariance 

            ell = 1/4; 
            sf  = 1;

            % hyper-parameters
            hyp.mean = 0; 
            hyp.lik  = log(sigma); 
            hyp.cov  = log([ell; sf]); 
            
            self.srgt.gpconf( hyp, meanfunc, covfunc, eta );
            
        end
        
        function out = run( self, objfun, domain, Nmax, upc, verb )
        %
        % objfun:
        %   Function handle taking a candidate sample and returning a scalar.
        %   Candidate sample size will be 1 x Ndim.
        %   The optimisation MAXIMISES this function.
        %
        % domain:
        %   Ndim x 2 matrix specifying the boundaries of the hypercube.
        %
        % Nmax:
        %   Maximum number of function evaluation.
        %   This can be considered as a "budget" for the optimisation.
        %   Note that the actual number of evaluations can exceed this value (usually not by much).
        %
        % upc: default 2*Ndims
        %   Update constant for GP hyperparameters.
        %   Hyperparameter updates will occur after number of splits:
        %       upc*n*(n+1)/2   for   n=1,2...
        %
        % verb: default true
        %   Verbose switch.
        %
        % JH
        
            assert( ismatrix(domain) && ~isempty(domain) && ... 
                size(domain,2)==2 && all(diff(domain,1,2) > eps), 'Bad domain.' );
        
            Ndim = size(domain,1);
            if nargin < 6, verb=true; end
            if nargin < 5 || isempty(upc), upc=2*Ndim; end
            
            assert( dk.is.integer(Nmax) && Nmax>1, 'Nmax should be >1.' );
            assert( dk.is.number(upc) && upc>1, 'upc should be >1.' );
            assert( isscalar(verb) && islogical(verb), 'verb should be boolean.' );
            
            self.iter = {};
            self.verb = verb;
            
            % initialisation
            self.info( 'Starting %d-dimensional optimisation, with a budget of %d evaluations...', Ndim, Nmax );
            self.initialise( domain, objfun );
            self.notify( 'PostInitialise' );
            
            % iterate
            LB = self.srgt.best_score();
            XI = 1;
            upn = 1;
            Niter = 0;
            tstart = tic;
            XI_max = self.max_search_depth();
            
            gpml_start();
            while self.srgt.Ne < Nmax
                
                Niter = Niter+1;
                self.info('\n\t------------------------------ Elapsed time: %s', dk.time.sec2str(toc(tstart)) );
                self.info('\tIteration #%d (depth: %d, neval: %d, score: %g)', ...
                    Niter, self.tree.depth, self.srgt.Ne, LB );
                
                % run steps
                LB = self.step_1(LB,objfun);
                [i_max,k_max,g_max] = self.step_2(objfun);
                [i_max,k_max] = self.step_3(i_max,k_max,g_max,XI);
                
                if any(i_max)
                    self.step_4(i_max,k_max); 
                else
                    warning( 'No remaining leaf after step 3, aborting.' );
                    break;
                end
                
                % update lower bound
                LB_old = LB;
                LB = self.srgt.best_score();
                
                % update iteration data
                self.iter{Niter} = [XI, nnz(i_max), LB];
                
                % update XI (line 38)
                if LB_old == LB
                    XI = max( 1, XI - 2^-1 );
                else
                    XI = min( XI_max, XI + 2^2 );
                end
                
                % update GP hyper parameters
                upn=self.update_quadratic(upc,upn);
                self.notify( 'PostIteration' );
                
            end
            gpml_stop();
            
            self.notify( 'PreFinalise' );
            out = self.finalise();
            
            self.info('Best score out of %d samples: %g', numel(out.samp.f), out.sol.f);
            self.info('Total runtime: %s', dk.time.sec2str(toc(tstart)) );
            
        end
        
        % serialise data to be saved
        function D = serialise(self,filename)
            D.iter = self.iter;
            D.tree = self.tree.serialise();
            D.surrogate = self.srgt.serialise();
            D.version = '0.1';
            
            if nargin > 1
                save( filename, '-v7', '-struct', 'D' );
            end
        end
        function self=unserialise(self,D)
            
            if ischar(D)
                D = load(D);
            end
            self.iter = D.iter;
            self.tree = GPSO_Tree().unserialise(D.tree);
            self.srgt = GP_Surrogate().unserialise(D.surrogate);
        end
        
    end
    
    methods (Hidden,Access=private)
        
        function upn=update_linear(self,upc,upn)
            Nsplit = self.tree.Ns;
            if Nsplit >= upc*upn

                self.info('\tHyperparameter update (n=%d).',upn);
                self.srgt.gp_update();
                upn = dk.math.nextint( Nsplit/upc );
                self.notify( 'PostUpdate' );

            end
        end
        
        function upn=update_quadratic(self,upc,upn)
            Nsplit = self.tree.Ns;
            if 2*Nsplit >= upc*upn*(upn+1)

                self.info('\tHyperparameter update (n=%d).',upn);
                self.srgt.gp_update();
                upn = dk.math.nextint( (sqrt(1+8*Nsplit/upc)-1)/2 );
                self.notify( 'PostUpdate' );

            end
        end
        
        function XI_max = max_search_depth(self)
            switch floor(self.srgt.Nd/10)
                case 0 % below 10
                    XI_max = 8;
                case 1 % below 20
                    XI_max = 5;
                otherwise % 20 and more
                    XI_max = 3;
            end
        end
        
        % print messages
        function info(self,fmt,varargin)
            if self.verb
                fprintf( [fmt '\n'], varargin{:} );
            end
        end
        
        function initialise(self,domain,objfun)
            
            % initialise surrogate
            self.srgt.init( domain );
            x_init = mean(domain'); %#ok
            f_init = objfun(x_init);
            self.srgt.append( x_init, f_init, 0, false );
            
            % initialise tree
            self.tree.init(self.srgt.Nd);
            
        end
        
        function out = finalise(self)
            
            % list all evaluated samples
            [x,f] = self.srgt.samp_evaluated(true);
            out.samp.x = x;
            out.samp.f = f;
            
            % get best sample
            [x,f] = self.srgt.best_sample(true);
            out.sol.x = x;
            out.sol.f = f;
            
        end
        
        function LB = step_1(self,LB,objfun)
            
            self.info('\tStep 1:');
            
            % update UCB
            self.info('\t\tUpdate UCB.');
            self.srgt.ucb_update();
            
            % find leaves with UCB > LB 
            % NOTES: 
            % 1. we know these are GP-based, if any, because LB is updated before each iteration
            % 2. there are no non-leaf GP-based nodes, because of step 2
            k = find( self.srgt.ucb > LB ); 
            n = numel(k);
            
            % evaluate those samples and update UCB again
            if n > 0
                self.info('\t\tFound %d nodes with UCB > LB, evaluating...',n);
                x = self.srgt.coord( k, true );
                f = nan(n,1);
                for i = 1:n
                    f(i) = objfun(x(i,:));
                end
                self.srgt.edit( k, f );
                self.srgt.ucb_update();
                LB = max([ LB; f ]);
                self.info('\t\tNew best score is: %g',LB);
            end
            
        end
        
        function [i_max,k_max,g_max] = step_2(self,objfun)
            
            self.info('\tStep 2:');
            depth = self.tree.depth;
            i_max = zeros(depth,1);
            k_max = zeros(depth,1);
            g_max = -inf(depth,1);
            upucb = false; 
            v_max = -inf;
            
            for h = 1:depth
                
                v_bak = v_max;
                while true
                    
                    % restore maximum value so far
                    v_max = v_bak; 
                    
                    % find leaf node with score greater than any larger leaf node
                    width = self.tree.width(h);
                    for i = 1:width
                        if self.tree.leaf(h,i)
                            k = self.tree.samp(h,i);
                            g_hi = self.srgt.ucb(k);
                            if g_hi > v_max
                                v_max = g_hi;
                                i_max(h) = i;
                                k_max(h) = k;
                                g_max(h) = g_hi;
                            end
                        end
                    end
                    
                    kmax = k_max(h);
                    if (kmax > 0) && self.srgt.gp_based(kmax)
                        self.info('\t\t[h=%02d] Sampling GP-based leaf %d with UCB %g',h,kmax,v_max);
                        self.srgt.edit( kmax, objfun(self.srgt.coord(kmax,true)) );
                        upucb = true;
                    else
                        break; % either no selection, or selection is already sampled
                    end
                                        
                end % while
                
                if i_max(h)
                    self.info('\t\t[h=%02d] Select leaf %d with score %g',h,i_max(h),v_max);
                else
                    self.info('\t\t[h=%02d] No leaf selected',h);
                end
                
            end % for
            
            if upucb
                self.info('\t\tUpdating UCB.');
                self.srgt.ucb_update();
            end
            
        end
        
        function [i_max,k_max] = step_3(self,i_max,k_max,g_max,XI)
            
            self.info('\tStep 3:');
            depth = self.tree.depth; 
            
            % number of UCB that would be used if the current number of selected leaves were split
            Ng = self.srgt.Ng;
            Ni = nnz(i_max);
            
            M1 = @(i) Ng + 2*Ni; % constant with depth
            M2 = @(i) Ng + 2*(Ni+i-1); % linear increase with depth
            M3 = @(i) Ng + 2*(Ni+i*(i-1)/2); % quadratic increase with depth
            varsigma = @(i) self.srgt.GP.varsigma(M2(i));
            
            for h = 1:depth
            if i_max(h) > 0
                
                % Search depth:
                %   - cannot be deeper than the tree (duh), 
                %   - is bounded by XI_max.
                sdepth = 0;
                h2_max = min( depth, ceil(h+XI) );
                for h2 = (h+1) : h2_max 
                    if i_max(h2) > 0
                        sdepth = h2 - h; break;
                    end
                end
                if sdepth == 0, continue; end
                
                % Find out whether any downstream interval has a UCB greater than 
                % currently best known score at matched depth.
                %
                % Do this by artificially expanding the GP tree and using GP-UCB
                % to compute expected scores.
                T = dk.struct.repeat( {'lower','upper','coord'}, sdepth+1, 1 );
                
                T(1).lower = self.tree.lower(h,i_max(h));
                T(1).upper = self.tree.upper(h,i_max(h));
                T(1).coord = self.srgt.coord(k_max(h));
                
                z_max = -inf;
                for h2 = 1:sdepth
                    for i2 = 1:3^(h2-1)

                        [g,d,x,s]  = split_largest_dimension( T(h2), i2, T(h2).coord(i2,:) );
                        [mu,sigma] = self.srgt.gp_call( [g;d] );
                        z_max      = max( mu + varsigma(h2)*sigma );

                        if z_max >= g_max(h+sdepth), break; end % early cancelling

                        U = split_tree( T(h2), i2, g, d, x, s );
                        T(h2+1).coord = [ T(h2+1).coord; U.coord ];
                        T(h2+1).lower = [ T(h2+1).lower; U.lower ];
                        T(h2+1).upper = [ T(h2+1).upper; U.upper ];

                    end
                    if z_max >= g_max(h+sdepth), break; end % "chain-break"
                end
                
                % If none of the downstream intervals has an "interesting" score, ignore it for this iteration.
                if z_max < g_max(h+sdepth)
                    i_max(h) = 0; 
                    k_max(h) = 0;
                    self.info('\t\t[h=%02d,search=%d] Drop selection (expected=%g < known=%g)',h,sdepth,z_max,g_max(h+sdepth));
                else
                    self.info('\t\t[h=%02d,search=%d] Maintain selection with expected score %g',h,sdepth,z_max);
                end
                
            end % if
            end % for
            
        end
        
        function step_4(self,i_max,k_max)
            
            self.info('\tStep 4:');
            depth = self.tree.depth;
            
            for h = 1:depth
            if i_max(h) > 0
                
                imax = i_max(h);
                kmax = k_max(h);
                
                % Split leaf along largest dimension
                [g,d,x,s] = split_largest_dimension( self.tree.level(h), imax, self.srgt.coord(kmax) );
                
                % Compute extents of new intervals
                U = split_tree( self.tree.level(h), imax, g, d, x, s );
                [mu,sigma] = self.srgt.gp_call( [g;d] );
                k = self.srgt.append( [g;d], mu, sigma, true );
                
                % Commit split to tree member
                self.tree.split( [h,imax], U.lower, U.upper, [k,kmax] );
                self.info('\t\t[h=%02d] Split dimension %d of leaf %d',h,s,imax);
                
            end % if
            end % for
            
        end
        
    end
    
end

% 
%       T.lower(k,:)              T.upper(k,:)
% Lvl      \                         /
% k:        =-----------x-----------=
% 
%
% k+1:      =---g---=---x---=---d---=
%          /        |       |        \
%        Tmin     Gmax     Dmin      Tmax
%

function [g,d,x,s] = split_largest_dimension(T,k,x)

    g = x;
    d = x;

    Tmin = T.lower(k,:);
    Tmax = T.upper(k,:);
    
    [~,s] = max( Tmax - Tmin );
    g(s)  = (5*Tmin(s) +   Tmax(s))/6;
    d(s)  = (  Tmin(s) + 5*Tmax(s))/6;
    
end

function U = split_tree(T,k,g,d,x,s)

    Tmin = T.lower(k,:);
    Tmax = T.upper(k,:);
    
    Gmax = Tmax;
    Dmin = Tmin;
    Xmin = Tmin;
    Xmax = Tmax;
    
    Gmax(s) = (2*Tmin(s) +   Tmax(s))/3.0;
    Dmin(s) = (  Tmin(s) + 2*Tmax(s))/3.0;
    Xmin(s) = Gmax(s);
    Xmax(s) = Dmin(s);
    
    U.coord = [g;d;x];
    U.lower = [Tmin;Dmin;Xmin];
    U.upper = [Gmax;Tmax;Xmax];

end
